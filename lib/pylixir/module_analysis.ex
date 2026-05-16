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

  @mutation_methods ~w(append sort update add discard clear pop remove extend insert reverse)

  @doc """
  Analyse a Python `Module.body` list. Returns a fully-populated
  `%Pylixir.ModuleAnalysis{}`.
  """
  @spec analyze([map()]) :: t()
  def analyze(body) when is_list(body) do
    promotable = mutation_free_literal_names(body)
    {attrs, fns, stmts} = partition(body, promotable)
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

  defp literal?(%{"_type" => "Constant"}), do: true
  defp literal?(%{"_type" => "List", "elts" => elts}), do: Enum.all?(elts, &literal?/1)
  defp literal?(%{"_type" => "Tuple", "elts" => elts}), do: Enum.all?(elts, &literal?/1)

  defp literal?(%{"_type" => "Dict", "keys" => ks, "values" => vs}) do
    Enum.all?(ks, &literal?/1) and Enum.all?(vs, &literal?/1)
  end

  defp literal?(_), do: false

  # --- Mutation predicates ----------------------------------------------

  defp mutated_anywhere?(body, name) do
    Enum.any?(body, fn node ->
      Walk.walk_scope(node, false, fn n, acc -> acc or mutates_name?(n, name) end)
    end)
  end

  defp mutates_name?(%{"_type" => "Assign", "targets" => targets}, name) do
    Enum.any?(targets, &target_mentions?(&1, name))
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
