defmodule Pylixir.Converter do
  @moduledoc """
  Recursive dispatcher that walks a Python AST (decoded JSON map) and emits
  Elixir AST tuples (RFC §3.2).

  The entry point for a `Module` node is `convert/3` — it takes the
  pre-computed `%Pylixir.ModuleAnalysis{}` from `Pylixir.ModuleAnalysis.analyze/1`
  as a third argument so partition/derived facts are computed once and
  threaded in. All other node types are converted via `convert/2`; the
  catch-all clause raises `Pylixir.UnsupportedNodeError`.
  """

  alias Pylixir.{Context, HelpersCodegen, ModuleAnalysis, Naming, UnsupportedNodeError}

  @type elixir_ast :: Macro.t()

  @doc """
  Convert a Python `Module` node with its pre-computed analysis. The Module
  clause owns the wrapper-emission shape: helpers + module attributes +
  defp's + `def py_main, do: <runtime>` + trailing `TranslatedCode.py_main()`.
  """
  @spec convert(map(), Context.t(), ModuleAnalysis.t()) :: {elixir_ast(), Context.t()}
  def convert(%{"_type" => "Module"}, context, %ModuleAnalysis{} = analysis) do
    attr_names =
      for {name, _value} <- analysis.module_attrs, into: MapSet.new(), do: name

    context = %{context | module_attrs: attr_names}

    {attr_asts, context} = convert_module_attrs(analysis.module_attrs, context)
    {fn_asts, context} = convert_each(analysis.function_defs, context)
    {stmt_asts, context} = convert_each(analysis.runtime_statements, context)

    helpers = HelpersCodegen.helpers_ast()
    body_block = helpers ++ attr_asts ++ fn_asts ++ [py_main_def(stmt_asts)]

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

  @doc """
  Convert a single Python AST node to an Elixir AST tuple.

  Returns `{elixir_ast, updated_context}`. Threads the context through
  recursive calls so nested constructs can update scope / counters.
  """
  @spec convert(map(), Context.t()) :: {elixir_ast(), Context.t()}
  def convert(%{"_type" => "UnaryOp", "op" => op, "operand" => operand} = node, context) do
    {operand_ast, context} = convert(operand, context)
    {unary_op_ast(op, operand_ast, node), context}
  end

  def convert(%{"_type" => "BinOp", "op" => op, "left" => left, "right" => right} = node, context) do
    {left_ast, context} = convert(left, context)
    {right_ast, context} = convert(right, context)
    {bin_op_ast(op, left_ast, right_ast, node), context}
  end

  def convert(%{"_type" => "List", "elts" => elts}, context) do
    reject_starred!(elts, "List")
    {asts, context} = convert_each(elts, context)
    {asts, context}
  end

  def convert(%{"_type" => "Tuple", "elts" => elts}, context) do
    reject_starred!(elts, "Tuple")
    {asts, context} = convert_each(elts, context)

    tuple_ast =
      case asts do
        [a, b] -> {a, b}
        _ -> {:{}, [], asts}
      end

    {tuple_ast, context}
  end

  def convert(%{"_type" => "Dict", "keys" => keys, "values" => values} = node, context) do
    reject_dict_unpack!(keys, node)
    {key_asts, context} = convert_each(keys, context)
    {value_asts, context} = convert_each(values, context)
    pairs = Enum.zip(key_asts, value_asts)
    {{:%{}, [], pairs}, context}
  end

  def convert(%{"_type" => "Name"} = node, context) do
    id = Map.fetch!(node, "id")

    cond do
      id == "__name__" ->
        {"__main__", context}

      Naming.reserved_prefix?(id) ->
        raise UnsupportedNodeError,
          node_type: "Name",
          hint:
            "Python identifier `#{id}` starts with a reserved Pylixir prefix (`var_`/`py_`) — rename it",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      MapSet.member?(context.module_attrs, id) ->
        attr_name = String.to_atom("var_" <> id)
        {{:@, [], [{attr_name, [], nil}]}, context}

      true ->
        atom = id |> Naming.rewrite() |> String.to_atom()
        {{atom, [], nil}, context}
    end
  end

  def convert(%{"_type" => "Constant"} = node, context) do
    case Map.fetch!(node, "value") do
      %{"_unsupported_literal" => kind} = tagged ->
        raise UnsupportedNodeError,
          node_type: "Constant",
          hint: unsupported_literal_hint(kind, tagged),
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      value when is_integer(value) or is_float(value) or is_binary(value) ->
        {value, context}

      value when is_boolean(value) or is_nil(value) ->
        {value, context}

      other ->
        raise UnsupportedNodeError,
          node_type: "Constant",
          hint: "unrecognised constant value shape: #{inspect(other, limit: 3)}",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  def convert(%{"_type" => type} = node, _context) do
    raise UnsupportedNodeError,
      node_type: type,
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # --- Operator emission -------------------------------------------------

  defp unary_op_ast(%{"_type" => "UAdd"}, operand_ast, _node), do: operand_ast
  defp unary_op_ast(%{"_type" => "USub"}, operand_ast, _node), do: {:-, [], [operand_ast]}

  defp unary_op_ast(%{"_type" => "Invert"}, operand_ast, _node) do
    {{:., [], [{:__aliases__, [], [:Bitwise]}, :bnot]}, [], [operand_ast]}
  end

  defp unary_op_ast(%{"_type" => "Not"}, operand_ast, _node) do
    {:!, [], [{:truthy?, [], [operand_ast]}]}
  end

  defp unary_op_ast(%{"_type" => other}, _operand_ast, node) do
    raise UnsupportedNodeError,
      node_type: other,
      hint: "unary operator `#{other}` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp bin_op_ast(%{"_type" => "Add"}, l, r, _node), do: {:py_add, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Sub"}, l, r, _node), do: {:-, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Mult"}, l, r, _node), do: {:py_mult, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Div"}, l, r, _node), do: {:/, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Pow"}, l, r, _node), do: {:py_pow, [], [l, r]}

  defp bin_op_ast(%{"_type" => other}, _l, _r, node) do
    raise UnsupportedNodeError,
      node_type: other,
      hint: "binary operator `#{other}` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # --- Literal-container rejections --------------------------------------

  defp reject_starred!(elts, container_type) do
    Enum.each(elts, fn
      %{"_type" => "Starred"} = starred ->
        raise UnsupportedNodeError,
          node_type: "Starred",
          hint:
            "star-unpack inside a #{container_type} literal (`[*xs, ...]`) is not supported; use `xs + [...]` instead",
          lineno: Map.get(starred, "lineno"),
          col_offset: Map.get(starred, "col_offset")

      _ ->
        :ok
    end)
  end

  defp reject_dict_unpack!(keys, dict_node) do
    if Enum.any?(keys, &is_nil/1) do
      raise UnsupportedNodeError,
        node_type: "Dict",
        hint: "dict-unpack (`{**d}`) is not supported",
        lineno: Map.get(dict_node, "lineno"),
        col_offset: Map.get(dict_node, "col_offset")
    end
  end

  # --- Constant unsupported-literal hint --------------------------------

  defp unsupported_literal_hint("complex", %{"repr" => repr}),
    do: "Python complex literal `#{repr}` is not supported"

  defp unsupported_literal_hint("bytes", %{"repr" => repr}),
    do: "Python bytes literal `#{repr}` is not supported"

  defp unsupported_literal_hint("ellipsis", _),
    do: "Python Ellipsis literal `...` is not supported"

  defp unsupported_literal_hint(kind, _),
    do: "Python literal of kind `#{kind}` is not supported"

  # --- Module-wrapper emission helpers ----------------------------------

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
