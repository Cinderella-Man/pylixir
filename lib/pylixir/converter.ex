defmodule Pylixir.Converter do
  @moduledoc """
  Recursive dispatcher that walks a Python AST (decoded JSON map) and emits
  Elixir AST tuples (RFC §3.2).

  Each ticket adds clauses for new `_type` values. The default catch-all clause
  raises `Pylixir.UnsupportedNodeError` so silent omissions are impossible.
  """

  alias Pylixir.AST.Walk
  alias Pylixir.{Context, HelpersCodegen, UnsupportedNodeError}

  @type elixir_ast :: Macro.t()

  @doc """
  Convert a single Python AST node to an Elixir AST tuple.

  Returns `{elixir_ast, updated_context}`. Threads the context through
  recursive calls so nested constructs can update scope / counters.
  """
  @spec convert(map(), Context.t()) :: {elixir_ast(), Context.t()}
  def convert(%{"_type" => "Module"} = node, context) do
    body = Map.get(node, "body", [])
    {module_attrs, function_defs, runtime_statements} = partition_module_body(body)

    attr_names = for {name, _value} <- module_attrs, into: MapSet.new(), do: name
    context = %{context | module_attrs: attr_names}

    {attr_asts, context} = convert_module_attrs(module_attrs, context)
    {fn_asts, context} = convert_each(function_defs, context)
    {stmt_asts, context} = convert_each(runtime_statements, context)

    helpers = HelpersCodegen.helpers_ast()

    body_block =
      helpers ++ attr_asts ++ fn_asts ++ [py_main_def(stmt_asts)]

    defmodule_ast =
      {:defmodule, [],
       [
         {:__aliases__, [], [:TranslatedCode]},
         [do: {:__block__, [], body_block}]
       ]}

    trailing_call =
      {{:., [], [{:__aliases__, [], [:TranslatedCode]}, :py_main]}, [], []}

    {{:__block__, [], [defmodule_ast, trailing_call]}, context}
  end

  def convert(%{"_type" => type} = node, _context) do
    raise UnsupportedNodeError,
      node_type: type,
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  @doc """
  Pre-pass over a Module body that collects every top-level `FunctionDef`
  name. Used to seed `Pylixir.Context.known_functions` so call sites can
  reference functions defined later in the source (RFC §10.3).

  Nested function definitions are deliberately excluded — they are local
  bindings, not module-level functions.
  """
  @spec collect_function_names([map()]) :: MapSet.t(String.t())
  def collect_function_names(body) when is_list(body) do
    body
    |> Enum.filter(&match?(%{"_type" => "FunctionDef"}, &1))
    |> Enum.map(& &1["name"])
    |> MapSet.new()
  end

  # --- Module body partitioning (T05 two-pass) -----------------------------

  @doc false
  @spec partition_module_body([map()]) ::
          {module_attrs :: [{String.t(), map()}], function_defs :: [map()],
           runtime_statements :: [map()]}
  def partition_module_body(body) when is_list(body) do
    promotable_names = mutation_free_literal_names(body)

    Enum.reduce(body, {[], [], []}, fn node, {attrs, fns, stmts} ->
      cond do
        match?(%{"_type" => "FunctionDef"}, node) ->
          {attrs, [node | fns], stmts}

        (name = literal_assign_name(node)) && MapSet.member?(promotable_names, name) ->
          {[{name, node["value"]} | attrs], fns, stmts}

        true ->
          {attrs, fns, [node | stmts]}
      end
    end)
    |> then(fn {a, f, s} -> {Enum.reverse(a), Enum.reverse(f), Enum.reverse(s)} end)
  end

  # Names of top-level literal Assigns that are never mutated downstream.
  # Pass 1 of the partition (T05). Walking uses Pylixir.AST.Walk so
  # reassignments inside nested function/lambda/class/comprehension bodies
  # — which are scope-local in Python — don't taint the outer name.
  defp mutation_free_literal_names(body) do
    candidates =
      body
      |> Enum.flat_map(fn node ->
        case literal_assign_name(node) do
          nil -> []
          name -> [name]
        end
      end)
      |> MapSet.new()

    Enum.reduce(candidates, candidates, fn name, acc ->
      if mutated_anywhere?(body, name), do: MapSet.delete(acc, name), else: acc
    end)
  end

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

  @mutation_methods ~w(append sort update add discard clear pop remove extend insert reverse)

  defp mutated_anywhere?(body, name) do
    Enum.any?(body, fn node ->
      Walk.walk_scope(node, false, fn n, acc -> acc or mutates_name?(n, name) end)
    end)
  end

  defp mutates_name?(%{"_type" => "Assign", "targets" => targets}, name) do
    Enum.any?(targets, fn
      %{"_type" => "Name", "id" => ^name} -> true
      _ -> false
    end)
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

  defp mutates_name?(%{"_type" => "For", "target" => %{"_type" => "Name", "id" => target}}, name),
    do: target == name

  defp mutates_name?(_, _), do: false

  defp aug_target_root_name(%{"_type" => "Name", "id" => id}), do: id

  defp aug_target_root_name(%{"_type" => "Subscript", "value" => value}),
    do: aug_target_root_name(value)

  defp aug_target_root_name(%{"_type" => "Attribute", "value" => value}),
    do: aug_target_root_name(value)

  defp aug_target_root_name(_), do: nil

  defp convert_module_attrs([], context), do: {[], context}

  defp convert_module_attrs([{name, value_node} | rest], context) do
    {value_ast, context} = convert(value_node, context)
    attr = {:@, [], [{:"var_#{name}", [], [value_ast]}]}
    {rest_asts, context} = convert_module_attrs(rest, context)
    {[attr | rest_asts], context}
  end

  defp convert_each(nodes, context) do
    {asts, context} =
      Enum.reduce(nodes, {[], context}, fn node, {acc, ctx} ->
        {ast, ctx} = convert(node, ctx)
        {[ast | acc], ctx}
      end)

    {Enum.reverse(asts), context}
  end

  defp py_main_def([]) do
    {:def, [], [{:py_main, [], nil}, [do: nil]]}
  end

  defp py_main_def([single]) do
    {:def, [], [{:py_main, [], nil}, [do: single]]}
  end

  defp py_main_def(many) do
    {:def, [], [{:py_main, [], nil}, [do: {:__block__, [], many}]]}
  end
end
