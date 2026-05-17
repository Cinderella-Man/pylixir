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
          known_functions: MapSet.t(String.t()),
          class_defs: [Pylixir.ClassAnalysis.t()],
          module_doc: nil | String.t()
        }

  defstruct module_attrs: [],
            function_defs: [],
            runtime_statements: [],
            known_functions: MapSet.new(),
            class_defs: [],
            module_doc: nil

  @mutation_methods ~w(append sort update add discard clear pop popleft remove extend insert reverse setdefault
                       intersection_update difference_update symmetric_difference_update)

  # Python convention (PEP 257): a module's first statement, if a bare
  # string Constant followed by *other statements*, is the docstring.
  # Extract it so the Converter can emit `@moduledoc` and drop it from
  # the body so Elixir doesn't warn about an unused literal in py_main.
  # A 1-statement module that's just a string isn't a docstring — it's
  # the actual return value (`Pylixir.transpile("\"hi\"")`).
  defp extract_module_docstring([
         %{"_type" => "Expr", "value" => %{"_type" => "Constant", "value" => v}}
         | [_ | _] = rest
       ])
       when is_binary(v),
       do: {v, rest}

  defp extract_module_docstring(body), do: {nil, body}

  @doc """
  Analyse a Python `Module.body` list. Returns a fully-populated
  `%Pylixir.ModuleAnalysis{}`.
  """
  @spec analyze([map()]) :: t()
  # `referenced_names` walks the AST passing a `shadowed` MapSet
  # through Lambda/Comp/FunctionDef bodies. Dialyzer flags every
  # MapSet.union/member? call as an opacity violation because the
  # MapSet shape transits an `any()`-typed third arg — a known
  # false-positive pattern (same shape as the `analyze` suppression
  # in `Pylixir.LoopAnalysis`).
  @dialyzer {:nowarn_function, referenced_names: 3}

  def analyze(body) when is_list(body) do
    {module_doc, body} = extract_module_docstring(body)
    {class_nodes, body_no_classes} = extract_classes(body)
    class_defs = Enum.map(class_nodes, &Pylixir.ClassAnalysis.analyze/1)
    promotable = mutation_free_literal_names(body_no_classes)
    reject_mutated_in_top_defs!(body_no_classes, promotable)
    {attrs, fns, stmts} = partition(body_no_classes, promotable)

    # Elixir warns (treated as a compile error in our test harness)
    # when a module attribute is set but never used. Drop any promoted
    # attr whose name isn't referenced anywhere — those flow back into
    # runtime_statements as plain Assigns at their original position.
    {attrs, demoted_attr_names} = drop_unused_attrs(attrs, body)

    # A top-level `defp` lives at module scope and can't see bindings
    # introduced inside `py_main` (where mutable top-level state lives).
    # If a FunctionDef's body has free references to such names, demote
    # it back into runtime_statements at its original position — the
    # nested-FunctionDef path will emit it as a `name = fn ... end`
    # lambda closure that does close over the surrounding scope.
    mutable_module_names = mutable_top_level_names(body, attrs)
    {fns, demoted_fns} = demote_closures(fns, mutable_module_names)

    stmts = merge_in_original_order(body, stmts, demoted_fns, demoted_attr_names)

    known = MapSet.new(fns, & &1["name"])

    %__MODULE__{
      module_attrs: attrs,
      function_defs: fns,
      runtime_statements: stmts,
      known_functions: known,
      class_defs: class_defs,
      module_doc: module_doc
    }
  end

  # Collect ClassDef nodes from both the module top AND any nested
  # position inside a top-level FunctionDef body (recursively across
  # If / While / For / Try, but stopping at nested FunctionDef /
  # Lambda / ClassDef boundaries — those have their own scope and
  # are handled in their own analyse pass if/when supported).
  # Hoisting means a class defined inside `def main():` becomes a
  # module-level `defp __cls_<Class>_*` that any function can call,
  # which matches how competitive-programming code uses these helper
  # classes (defined once, used throughout the script).
  defp extract_classes(body) do
    classes =
      Enum.flat_map(body, fn node ->
        collect_classes(node)
      end)

    {classes, body}
  end

  defp collect_classes(%{"_type" => "ClassDef"} = node) do
    inner = Enum.flat_map(Map.get(node, "body", []), &collect_classes/1)
    [node | inner]
  end

  defp collect_classes(%{"_type" => type} = node)
       when type in ["FunctionDef", "AsyncFunctionDef"] do
    Enum.flat_map(Map.get(node, "body", []), &collect_classes/1)
  end

  defp collect_classes(%{"_type" => type} = node)
       when type in ["If", "While", "For", "AsyncFor"] do
    Enum.flat_map(Map.get(node, "body", []), &collect_classes/1) ++
      Enum.flat_map(Map.get(node, "orelse", []), &collect_classes/1)
  end

  defp collect_classes(%{"_type" => "Try"} = node) do
    Enum.flat_map(Map.get(node, "body", []), &collect_classes/1) ++
      Enum.flat_map(Map.get(node, "orelse", []), &collect_classes/1) ++
      Enum.flat_map(Map.get(node, "finalbody", []), &collect_classes/1) ++
      Enum.flat_map(Map.get(node, "handlers", []), fn h ->
        Enum.flat_map(Map.get(h, "body", []), &collect_classes/1)
      end)
  end

  defp collect_classes(_), do: []

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
      # Fix-point: a function that references *another* demoted function
      # must itself be demoted (the demoted callee only exists inside
      # py_main's scope, so a `defp` caller can't reach it).
      do_demote_fixpoint(fns, mutable_names)
    end
  end

  defp do_demote_fixpoint(fns, names) do
    {kept, demoted} =
      Enum.split_with(fns, fn fn_node ->
        not function_uses_any?(fn_node, names)
      end)

    case demoted do
      [] ->
        {kept, []}

      _ ->
        # Add the newly-demoted names to the closure-binding set and
        # iterate over the remaining kept fns. Stop when no new fns
        # demote in a pass.
        names = Enum.reduce(demoted, names, fn fn_node, acc -> MapSet.put(acc, fn_node["name"]) end)
        {kept_final, demoted_rest} = do_demote_fixpoint(kept, names)
        {kept_final, demoted ++ demoted_rest}
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

  # Walk `body` in original order, replacing demoted FunctionDefs and
  # demoted (unused-attr) Assigns back into `stmts`. Preserves Python
  # execution order so `def foo(): ...` followed by `foo(x)` still
  # works, and `stable = True` flows through py_main as a no-op binding.
  defp merge_in_original_order(body, stmts, demoted_fns, demoted_attr_names) do
    demoted_fn_set = MapSet.new(demoted_fns, & &1["name"])
    # Whatever's currently in `stmts` already lives there — use a set
    # to keep that lookup O(1) below.
    stmts_set = MapSet.new(stmts)

    {merged, _} =
      Enum.reduce(body, {[], stmts}, fn node, {acc, remaining_stmts} ->
        cond do
          match?(%{"_type" => "FunctionDef"}, node) and
              MapSet.member?(demoted_fn_set, node["name"]) ->
            {[node | acc], remaining_stmts}

          match?(%{"_type" => "FunctionDef"}, node) ->
            {acc, remaining_stmts}

          # Demoted-attr Assign — was promoted to @var_X but the name
          # is never read, so restore it as a runtime statement.
          (name = literal_assign_name(node)) && MapSet.member?(demoted_attr_names, name) ->
            {[node | acc], remaining_stmts}

          # Literal Assign that's already in stmts (mutation kept it
          # out of the attr set) — pop from remaining_stmts so we don't
          # double-include.
          (_name = literal_assign_name(node)) && MapSet.member?(stmts_set, node) ->
            case remaining_stmts do
              [^node | rest] -> {[node | acc], rest}
              _ -> {[node | acc], remaining_stmts}
            end

          # Literal Assign that was promoted (in attrs, not in stmts).
          (name = literal_assign_name(node)) && name != nil ->
            {acc, remaining_stmts}

          true ->
            case remaining_stmts do
              [^node | rest] -> {[node | acc], rest}
              _ -> {acc, remaining_stmts}
            end
        end
      end)

    Enum.reverse(merged)
  end

  defp drop_unused_attrs(attrs, body) do
    referenced = referenced_names(body, MapSet.new())

    Enum.reduce(attrs, {[], MapSet.new()}, fn {name, _value} = entry, {kept, demoted} ->
      if MapSet.member?(referenced, name) do
        {[entry | kept], demoted}
      else
        {kept, MapSet.put(demoted, name)}
      end
    end)
    |> then(fn {kept, demoted} -> {Enum.reverse(kept), demoted} end)
  end

  # Collect every Name `id` that appears in a Load context. Names in
  # Store/Del context (Assign targets, augassign targets, for-loop
  # targets) don't count as reads. Without this, an unused
  # `STABLE = True` still looks "referenced" because its own target
  # is a Name, and the attr would never demote.
  #
  # Reads INSIDE a binding scope (lambda/comp/FunctionDef) that
  # rebinds the same name are *shadowed* — they refer to the local,
  # not the outer module attribute. We pass a `shadowed` set down on
  # entering each binding scope and skip Name reads matching it.
  # Without this, `x = 99; any(x > 3 for x in xs)` would count the
  # comp's `x` as a read of the outer x and keep `@var_x` promoted
  # → unused-attribute warning at compile time.
  defp referenced_names(nodes, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &referenced_names(&1, &2, MapSet.new()))

  defp referenced_names(node, acc), do: referenced_names(node, acc, MapSet.new())

  defp referenced_names(nodes, acc, shadowed) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &referenced_names(&1, &2, shadowed))

  defp referenced_names(%{"_type" => "Name", "id" => id} = node, acc, shadowed) do
    if MapSet.member?(shadowed, id) do
      acc
    else
      case node["ctx"] do
        %{"_type" => "Load"} -> MapSet.put(acc, id)
        nil -> MapSet.put(acc, id)
        _ -> acc
      end
    end
  end

  # Lambda — params shadow the surrounding scope inside the body.
  defp referenced_names(%{"_type" => "Lambda", "args" => args, "body" => body}, acc, shadowed) do
    inner = MapSet.union(shadowed, lambda_arg_names(args))
    referenced_names(body, acc, inner)
  end

  # FunctionDef — params + the function's name shadow the outer scope.
  # The `name` itself is the function's binding, but the *body* may
  # see it for recursion. Either way, treat params as shadowing reads
  # inside the body.
  defp referenced_names(%{"_type" => "FunctionDef", "args" => args, "body" => body}, acc, shadowed) do
    inner = MapSet.union(shadowed, lambda_arg_names(args))
    referenced_names(body, acc, inner)
  end

  # Comprehensions — for-targets across all generators shadow inside
  # the elt + ifs + later generators' iter/ifs. We approximate by
  # treating *all* generator targets as shadowed for elt/ifs/iter
  # (the first generator's iter actually evaluates in the enclosing
  # scope, but a shadow there would just miss promoting an attr that
  # the iter reads — the iter still gets the right *runtime* value
  # because Converter is scope-aware. Erring on "shadowed" here only
  # risks an over-aggressive demotion, which the previous-attr-not-
  # used post-check would have done anyway).
  defp referenced_names(%{"_type" => type, "elt" => elt, "generators" => gens}, acc, shadowed)
       when type in ["ListComp", "SetComp", "GeneratorExp"] do
    inner = MapSet.union(shadowed, comp_target_names(gens))
    acc = referenced_names(elt, acc, inner)
    referenced_names(gens, acc, inner)
  end

  defp referenced_names(%{"_type" => "DictComp", "key" => k, "value" => v, "generators" => gens}, acc, shadowed) do
    inner = MapSet.union(shadowed, comp_target_names(gens))
    acc = referenced_names(k, acc, inner)
    acc = referenced_names(v, acc, inner)
    referenced_names(gens, acc, inner)
  end

  defp referenced_names(%{"_type" => _} = node, acc, shadowed) do
    node
    |> Map.delete("_type")
    |> Enum.reduce(acc, fn {_k, v}, a -> referenced_names(v, a, shadowed) end)
  end

  defp referenced_names(_leaf, acc, _shadowed), do: acc

  defp lambda_arg_names(%{"args" => args} = arg_node) do
    posonly = Map.get(arg_node, "posonlyargs", [])
    kwonly = Map.get(arg_node, "kwonlyargs", [])
    vararg = Map.get(arg_node, "vararg")
    kwarg = Map.get(arg_node, "kwarg")

    extras =
      [vararg, kwarg]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Map.get(&1, "arg"))

    (posonly ++ args ++ kwonly)
    |> Enum.map(&Map.get(&1, "arg"))
    |> Kernel.++(extras)
    |> MapSet.new()
  end

  defp lambda_arg_names(_), do: MapSet.new()

  defp comp_target_names(generators) do
    generators
    |> Enum.flat_map(fn %{"target" => target} -> target_names(target) end)
    |> MapSet.new()
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

  # `Walk.walk_scope` deliberately stops at FunctionDef boundaries —
  # which means `memo[x] = ...` inside `def f(): ...` is invisible to
  # `mutated_anywhere?`. A name like `memo` then gets promoted to
  # `@var_memo` (immutable Elixir module attribute), the converter
  # rewrites the subscript-assign to `@var_memo = py_setitem(...)`,
  # and any read of `memo` AFTER the rebind emits bare `memo` (the
  # subscript-assign tags `memo` as a local in the surrounding
  # context). That bare reference fails to compile with
  # "undefined variable `memo`". Even when the read-after-assign
  # doesn't occur, the @-attr "rebind" is a runtime no-op so the
  # mutation is silently dropped — the memoization breaks invisibly.
  #
  # Reject the pattern at transpile time so the user refactors to
  # pass state explicitly through return values (the only shape
  # Pylixir's immutable lowering can model correctly).
  defp reject_mutated_in_top_defs!(body, promotable) do
    promotable
    |> Enum.find(fn name -> mutated_inside_top_def?(body, name) end)
    |> case do
      nil ->
        :ok

      name ->
        raise Pylixir.UnsupportedNodeError,
          node_type: "Module",
          hint:
            "module-level `#{name} = ...` is mutated inside a top-level `def` " <>
              "(e.g. `#{name}[x] = ...` or `#{name}.append(...)`). Pylixir lowers " <>
              "module-level literals to immutable Elixir module attributes, so " <>
              "the mutation can't persist. Refactor to pass `#{name}` explicitly " <>
              "through return values, or thread it as a function argument."
    end
  end

  defp mutated_inside_top_def?(body, name) do
    Enum.any?(body, fn
      %{"_type" => type, "body" => def_body}
      when type in ["FunctionDef", "AsyncFunctionDef"] ->
        not def_rebinds_name?(def_body, name) and def_mutates_name?(def_body, name)

      _ ->
        false
    end)
  end

  # A `name = ...` (bare Name LHS) anywhere in the def body shadows
  # the module-level name — Python's local-by-default rule. Subscript
  # mutations of that local don't reach the global, so we don't reject
  # the global's promotion in that case.
  defp def_rebinds_name?(def_body, name) do
    Enum.any?(def_body, fn n ->
      Walk.walk_scope(n, false, fn node, acc -> acc or assigns_local_name?(node, name) end)
    end)
  end

  defp assigns_local_name?(%{"_type" => "Assign", "targets" => targets}, name) do
    Enum.any?(targets, fn
      %{"_type" => "Name", "id" => id} -> id == name
      _ -> false
    end)
  end

  defp assigns_local_name?(_, _), do: false

  defp def_mutates_name?(def_body, name) do
    Enum.any?(def_body, fn n ->
      Walk.walk_scope(n, false, fn node, acc -> acc or mutates_name?(node, name) end)
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

  # `heapq.heappush(heap, item)` / `heapq.heapify(heap)` (and bare-Name
  # forms after `from heapq import …`) rebind `heap` via Converter's
  # Expr clause. ModuleAnalysis runs before stdlib aliases are tracked,
  # so the recognizer accepts the bare-Name form heuristically — see
  # `Pylixir.Stdlib.Heapq.statement_mutation_call/2` for the contract.
  defp mutates_name?(%{"_type" => "Expr", "value" => value}, name) do
    case Pylixir.Stdlib.Heapq.statement_mutation_call(value, nil) do
      {:ok, ^name, _, _} ->
        true

      _ ->
        case Pylixir.Stdlib.Bisect.statement_mutation_call(value, nil) do
          {:ok, ^name, _, _} -> true
          _ -> false
        end
    end
  end

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

  # `x = heappop(h)` (full `heapq.heappop(h)` or bare-Name after
  # `from heapq import heappop`) — rebinds h via Nodes.Assign's
  # destructure-match. Recognizer lives on Pylixir.Stdlib.Heapq.
  defp capture_return_mutates?(value, name) do
    case Pylixir.Stdlib.Heapq.capture_return_call(value, nil) do
      {:ok, ^name, _, _} -> true
      _ -> false
    end
  end

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
