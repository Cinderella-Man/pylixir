defmodule Pylixir.ModuleAnalysis do
  @moduledoc """
  Static analysis of a Python `Module.body`. Produces every fact
  downstream code generators need before per-statement conversion runs.

  Single public entry point: `analyze/1`. Returns a `%Pylixir.ModuleAnalysis{}`
  struct with four fields:

    * `:module_attrs` — `[{name, value_node}]`. Top-level literal `Assign`s
      whose target name is **never** mutated downstream. Emitted as
      `@var_<name>` Elixir module attributes (T05).
    * `:function_defs` — `[map()]`. Top-level `FunctionDef` nodes. Emitted
      as `defp`s at module level (T19).
    * `:runtime_statements` — `[map()]`. Everything else from `Module.body`
      (including literal Assigns that *did* get mutated downstream). Goes
      into `py_main`'s body in original order.
    * `:known_functions` — `MapSet.t(String.t())` of top-level
      `FunctionDef` names. Seeded into `Context.known_functions` so call
      sites can forward-reference functions defined later in the source
      (RFC §10.3).

  The analysis is **two-pass**:

    1. Walk `Module.body` looking for downstream mutations of each
       literal-Assign candidate. Names that survive go to `module_attrs`.
       The walk respects `Pylixir.AST.Walk` boundaries — reassignments
       inside nested function/lambda/class/comprehension scopes are
       scope-local in Python and do not taint the outer name.
    2. Classify each top-level statement into the appropriate bucket.

  Mutation detection covers every form that downstream code generators
  rewrite to a reassignment: direct `Assign`, `AugAssign` (including
  subscript/attribute targets via the root-name extraction), statement-
  context mutation methods (`append`, `sort`, `update`, `add`, etc.), and
  `For` loops whose target is the name.
  """

  alias Pylixir.AST.Walk

  @type t :: %__MODULE__{
          module_attrs: [{String.t(), map()}],
          function_defs: [map()],
          runtime_statements: [map()],
          known_functions: MapSet.t(String.t())
        }

  defstruct module_attrs: [],
            function_defs: [],
            runtime_statements: [],
            known_functions: MapSet.new()

  @mutation_methods ~w(append sort update add discard clear pop popleft remove extend insert reverse)

  @doc """
  Analyse a Python `Module.body` list. Returns a fully-populated
  `%Pylixir.ModuleAnalysis{}`.
  """
  @spec analyze([map()]) :: t()
  def analyze(body) when is_list(body) do
    promotable = mutation_free_literal_names(body)
    {attrs, fns, stmts} = partition(body, promotable)

    # A top-level `defp` lives at module scope and can't see bindings
    # introduced inside `py_main` (where mutable top-level state lives).
    # If a FunctionDef's body has free references to such names, demote
    # it back into runtime_statements at its original position — the
    # nested-FunctionDef path will emit it as a `name = fn ... end`
    # lambda closure that does close over the surrounding scope.
    mutable_module_names = mutable_top_level_names(body, attrs)
    {fns, demoted} = demote_closures(fns, mutable_module_names)
    stmts = merge_in_original_order(body, stmts, demoted)

    known = MapSet.new(fns, & &1["name"])

    %__MODULE__{
      module_attrs: attrs,
      function_defs: fns,
      runtime_statements: stmts,
      known_functions: known
    }
  end

  # --- Pass 2 — classification -------------------------------------------

  defp partition(body, promotable) do
    Enum.reduce(body, {[], [], []}, fn node, {attrs, fns, stmts} ->
      cond do
        match?(%{"_type" => "FunctionDef"}, node) ->
          {attrs, [node | fns], stmts}

        (name = literal_assign_name(node)) && MapSet.member?(promotable, name) ->
          {[{name, node["value"]} | attrs], fns, stmts}

        true ->
          {attrs, fns, [node | stmts]}
      end
    end)
    |> then(fn {a, f, s} -> {Enum.reverse(a), Enum.reverse(f), Enum.reverse(s)} end)
  end

  # --- Closure demotion --------------------------------------------------

  defp mutable_top_level_names(body, attrs) do
    promoted = MapSet.new(attrs, fn {name, _} -> name end)

    body
    |> Enum.reduce(MapSet.new(), fn node, acc ->
      case top_level_assigned_names(node) do
        [] -> acc
        names -> Enum.reduce(names, acc, &MapSet.put(&2, &1))
      end
    end)
    |> MapSet.difference(promoted)
  end

  defp top_level_assigned_names(%{"_type" => "Assign", "targets" => targets}) do
    Enum.flat_map(targets, &target_names/1)
  end

  defp top_level_assigned_names(%{"_type" => "AugAssign", "target" => target}),
    do: target_names(target)

  defp top_level_assigned_names(%{"_type" => "For", "target" => target}),
    do: target_names(target)

  # `from math import gcd, sqrt` — Converter emits `gcd = fn ... end`,
  # `sqrt = fn ... end` etc. at runtime position. These bindings live in
  # py_main's scope, so any defp referencing them must be demoted to a
  # closure for the same reason as mutable Assigns.
  defp top_level_assigned_names(%{"_type" => "ImportFrom", "names" => names}) do
    Enum.map(names, fn %{"name" => n} = entry -> Map.get(entry, "asname") || n end)
  end

  defp top_level_assigned_names(_), do: []

  defp target_names(%{"_type" => "Name", "id" => id}), do: [id]

  defp target_names(%{"_type" => "Tuple", "elts" => elts}),
    do: Enum.flat_map(elts, &target_names/1)

  defp target_names(%{"_type" => "List", "elts" => elts}),
    do: Enum.flat_map(elts, &target_names/1)

  defp target_names(%{"_type" => "Subscript", "value" => value}) do
    case aug_target_root_name(value) do
      nil -> []
      n -> [n]
    end
  end

  defp target_names(_), do: []

  defp demote_closures(fns, mutable_names) do
    if MapSet.size(mutable_names) == 0 do
      {fns, []}
    else
      Enum.split_with(fns, fn fn_node ->
        not function_uses_any?(fn_node, mutable_names)
      end)
    end
  end

  defp function_uses_any?(%{"args" => args, "body" => body}, names) do
    locals = function_local_names(args, body)
    Enum.any?(body, &refs_free_name?(&1, names, locals))
  end

  defp function_local_names(args, body) do
    param_names = arg_names(args)
    assigned = collect_assigned_names(body, MapSet.new())
    MapSet.union(MapSet.new(param_names), assigned)
  end

  defp arg_names(%{
         "args" => args,
         "posonlyargs" => po,
         "kwonlyargs" => kw,
         "vararg" => v,
         "kwarg" => k
       }) do
    plain = Enum.map(args, & &1["arg"])
    po_names = Enum.map(po || [], & &1["arg"])
    kw_names = Enum.map(kw || [], & &1["arg"])
    var = if v, do: [v["arg"]], else: []
    kwarg = if k, do: [k["arg"]], else: []
    plain ++ po_names ++ kw_names ++ var ++ kwarg
  end

  defp arg_names(%{"args" => args}), do: Enum.map(args || [], & &1["arg"])
  defp arg_names(_), do: []

  defp collect_assigned_names(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &collect_assigned_names/2)
  end

  defp collect_assigned_names(%{"_type" => "Assign", "targets" => targets}, acc) do
    Enum.reduce(targets, acc, fn t, a ->
      Enum.reduce(target_names(t), a, &MapSet.put(&2, &1))
    end)
  end

  defp collect_assigned_names(%{"_type" => "AugAssign", "target" => t}, acc) do
    Enum.reduce(target_names(t), acc, &MapSet.put(&2, &1))
  end

  defp collect_assigned_names(%{"_type" => "For", "target" => t, "body" => b, "orelse" => o}, acc) do
    acc = Enum.reduce(target_names(t), acc, &MapSet.put(&2, &1))
    acc = collect_assigned_names(b, acc)
    collect_assigned_names(o || [], acc)
  end

  defp collect_assigned_names(%{"_type" => "While", "body" => b, "orelse" => o}, acc) do
    acc = collect_assigned_names(b, acc)
    collect_assigned_names(o || [], acc)
  end

  defp collect_assigned_names(%{"_type" => "If", "body" => b, "orelse" => o}, acc) do
    acc = collect_assigned_names(b, acc)
    collect_assigned_names(o || [], acc)
  end

  defp collect_assigned_names(
         %{"_type" => "Try", "body" => b, "orelse" => o, "finalbody" => f, "handlers" => hs},
         acc
       ) do
    acc = collect_assigned_names(b, acc)
    acc = collect_assigned_names(o || [], acc)
    acc = collect_assigned_names(f || [], acc)
    Enum.reduce(hs || [], acc, fn h, a -> collect_assigned_names(h["body"] || [], a) end)
  end

  defp collect_assigned_names(%{"_type" => "With", "body" => b, "items" => items}, acc) do
    acc =
      Enum.reduce(items, acc, fn item, a ->
        case item["optional_vars"] do
          nil -> a
          tgt -> Enum.reduce(target_names(tgt), a, &MapSet.put(&2, &1))
        end
      end)

    collect_assigned_names(b, acc)
  end

  defp collect_assigned_names(%{"_type" => "FunctionDef", "name" => name}, acc),
    do: MapSet.put(acc, name)

  defp collect_assigned_names(_, acc), do: acc

  # Does this node reference any of `names` as a free variable (not
  # shadowed by `locals`)? Pre-order recursive over the AST; descends
  # into expressions but treats nested function/class bodies as opaque
  # (their own scope — their references are not the outer function's
  # responsibility).
  defp refs_free_name?(nodes, names, locals) when is_list(nodes) do
    Enum.any?(nodes, &refs_free_name?(&1, names, locals))
  end

  defp refs_free_name?(%{"_type" => type, "id" => id}, names, locals) when type == "Name" do
    MapSet.member?(names, id) and not MapSet.member?(locals, id)
  end

  defp refs_free_name?(%{"_type" => type}, _names, _locals)
       when type in ~w(FunctionDef AsyncFunctionDef Lambda ClassDef),
       do: false

  defp refs_free_name?(%{"_type" => _} = node, names, locals) do
    node
    |> Map.delete("_type")
    |> Enum.any?(fn {_k, v} -> refs_free_name?(v, names, locals) end)
  end

  defp refs_free_name?(_leaf, _names, _locals), do: false

  # Walk `body` in original order, replacing each demoted FunctionDef
  # at its original index back into `stmts`. Preserves Python execution
  # order so a `def foo(): ...` followed by `foo(x)` still works.
  defp merge_in_original_order(body, stmts, demoted) do
    demoted_set = MapSet.new(demoted, & &1["name"])

    {merged, _} =
      Enum.reduce(body, {[], stmts}, fn node, {acc, remaining_stmts} ->
        cond do
          match?(%{"_type" => "FunctionDef"}, node) and
              MapSet.member?(demoted_set, node["name"]) ->
            {[node | acc], remaining_stmts}

          match?(%{"_type" => "FunctionDef"}, node) ->
            {acc, remaining_stmts}

          # Top-level promotable literal Assign — skip; it became a module attr.
          (name = literal_assign_name(node)) && name != nil ->
            case remaining_stmts do
              [^node | rest] -> {[node | acc], rest}
              _ -> {acc, remaining_stmts}
            end

          true ->
            case remaining_stmts do
              [^node | rest] -> {[node | acc], rest}
              _ -> {acc, remaining_stmts}
            end
        end
      end)

    Enum.reverse(merged)
  end

  # --- Pass 1 — mutation-free literal names ------------------------------

  # For each top-level literal Assign at index `i`, walk every *other*
  # top-level node looking for mutations of that name. The Assign itself
  # is the initialiser, not a re-mutation, and must be excluded — but a
  # second literal Assign to the same name elsewhere counts (it would
  # silently overwrite the module attribute), so we exclude only the
  # candidate's own position.
  defp mutation_free_literal_names(body) do
    body
    |> Enum.with_index()
    |> Enum.reduce(MapSet.new(), &maybe_promote(&1, &2, body))
  end

  defp maybe_promote({node, idx}, acc, body) do
    with name when is_binary(name) <- literal_assign_name(node),
         others = List.delete_at(body, idx),
         false <- mutated_anywhere?(others, name) do
      MapSet.put(acc, name)
    else
      _ -> acc
    end
  end

  # --- Literal predicates ------------------------------------------------

  defp literal_assign_name(%{
         "_type" => "Assign",
         "targets" => [%{"_type" => "Name", "id" => name}],
         "value" => value
       }) do
    if literal?(value), do: name, else: nil
  end

  defp literal_assign_name(_), do: nil

  # Promotion to a module attribute is only safe when the value can be
  # evaluated at Elixir compile time (module-attribute scope can't call
  # same-module runtime helpers like `py_pow` or `py_sub`). Delegate to
  # `Pylixir.LiteralFold` so the promotability check and the actual
  # value emission in `Pylixir.Converter.convert_module_attrs/2` agree
  # on the same surface.
  defp literal?(node), do: match?({:ok, _}, Pylixir.LiteralFold.fold(node))

  # --- Mutation predicates ----------------------------------------------

  defp mutated_anywhere?(body, name) do
    Enum.any?(body, fn node ->
      Walk.walk_scope(node, false, fn n, acc -> acc or mutates_name?(n, name) end)
    end)
  end

  defp mutates_name?(%{"_type" => "Assign", "targets" => targets, "value" => value}, name) do
    Enum.any?(targets, &target_mentions?(&1, name)) or
      capture_return_mutates?(value, name)
  end

  defp mutates_name?(%{"_type" => "AugAssign", "target" => target}, name) do
    aug_target_root_name(target) == name
  end

  defp mutates_name?(
         %{
           "_type" => "Expr",
           "value" => %{
             "_type" => "Call",
             "func" => %{
               "_type" => "Attribute",
               "value" => %{"_type" => "Name", "id" => target_name},
               "attr" => method
             }
           }
         },
         name
       )
       when method in @mutation_methods,
       do: target_name == name

  # `coll[i].method(args)` — `Pylixir.Nodes.Mutations` rebinds `coll`,
  # so `coll` must NOT be promoted to a module attribute even though
  # its initial Assign is a literal.
  defp mutates_name?(
         %{
           "_type" => "Expr",
           "value" => %{
             "_type" => "Call",
             "func" => %{
               "_type" => "Attribute",
               "value" => %{
                 "_type" => "Subscript",
                 "value" => %{"_type" => "Name", "id" => target_name}
               },
               "attr" => method
             }
           }
         },
         name
       )
       when method in @mutation_methods,
       do: target_name == name

  defp mutates_name?(%{"_type" => "For", "target" => %{"_type" => "Name", "id" => target}}, name),
    do: target == name

  # `del coll[k]` — rebinds `coll`, so a top-level dict/list that's
  # later `del`'d-from must not be promoted to a module attribute.
  defp mutates_name?(%{"_type" => "Delete", "targets" => targets}, name) do
    Enum.any?(targets, fn
      %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => target_name}} ->
        target_name == name

      _ ->
        false
    end)
  end

  # `heapq.heappush(heap, item)` / `heapq.heapify(heap)` — Pylixir
  # rebinds `heap` (Converter Expr clause); ModuleAnalysis must
  # recognise these as mutations so an empty-list initialiser
  # (`heap = []`) isn't promoted to a module attribute.
  defp mutates_name?(
         %{
           "_type" => "Expr",
           "value" => %{
             "_type" => "Call",
             "func" => %{
               "_type" => "Attribute",
               "value" => %{"_type" => "Name", "id" => "heapq"},
               "attr" => method
             },
             "args" => [%{"_type" => "Name", "id" => target_name} | _]
           }
         },
         name
       )
       when method in ["heappush", "heapify"],
       do: target_name == name

  defp mutates_name?(_, _), do: false

  # `x = coll.pop()` / `a, b = coll.pop()` — Converter's `single_target_assign`
  # rebinds `coll` via `{popped, coll} = py_pop_*(coll, ...)`. Mirror the
  # mutation tracking so a top-level `coll = [...]` won't be promoted to
  # `@var_coll` (module attrs can't be re-bound). Same shape covers
  # `popleft` (cons-pattern destructure rebinds the tail).
  defp capture_return_mutates?(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => coll},
             "attr" => method
           }
         },
         name
       )
       when method in ["pop", "popleft"],
       do: coll == name

  defp capture_return_mutates?(_, _), do: false

  defp aug_target_root_name(%{"_type" => "Name", "id" => id}), do: id

  defp aug_target_root_name(%{"_type" => "Subscript", "value" => value}),
    do: aug_target_root_name(value)

  defp aug_target_root_name(%{"_type" => "Attribute", "value" => value}),
    do: aug_target_root_name(value)

  defp aug_target_root_name(_), do: nil

  # Does this assignment-target node bind/mutate the given name?
  # Recurses through Tuple destructure targets and through Subscript
  # targets (which T13 rewrites to a setitem reassigning the collection
  # root).
  defp target_mentions?(%{"_type" => "Name", "id" => id}, name), do: id == name

  defp target_mentions?(%{"_type" => "Tuple", "elts" => elts}, name) do
    Enum.any?(elts, &target_mentions?(&1, name))
  end

  defp target_mentions?(%{"_type" => "Subscript", "value" => value}, name) do
    aug_target_root_name(value) == name
  end

  defp target_mentions?(_, _), do: false
end
