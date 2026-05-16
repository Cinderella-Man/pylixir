defmodule Pylixir.Nodes.Compare do
  @moduledoc """
  Lower Python `Compare` nodes (one or more chained operators) to
  Elixir expressions.

  A single operator (`a < b`) emits a direct comparison via
  `pair_ast/3`. Chained operators (`a < b <= c`) emit a `&&`-chain of
  pair comparisons with single-evaluation temps for the non-trivial
  middle operands — preserves Python's "each middle is evaluated once"
  semantics (RFC §6.12).

  Entry point: `emit/4`. The cross-section pair lookup `pair_ast/3` is
  kept public so other emitters (none currently, but the lookup is
  small and well-defined) can reuse it.
  """

  alias Pylixir.{AST.Trivial, Converter}

  @spec emit(map(), [map()], [map()], Pylixir.Context.t()) ::
          {Macro.t(), Pylixir.Context.t()}
  def emit(left, [single_op], comparators, context) do
    [right_node] = comparators
    {left_ast, context} = Converter.convert(left, context)
    {right_ast, context} = Converter.convert(right_node, context)
    {pair_ast(single_op, left_ast, right_ast), context}
  end

  def emit(left, ops, comparators, context) do
    {left_ast, context} = Converter.convert(left, context)
    {middles, last} = Enum.split(comparators, length(comparators) - 1)

    {middle_refs, temp_bindings, context} = build_middle_refs(middles, context)

    {last_ast, context} = Converter.convert(hd(last), context)

    operand_asts = [left_ast | middle_refs] ++ [last_ast]
    pairs = build_compare_pairs(operand_asts, ops)
    [first_pair | rest_pairs] = pairs
    chain = Enum.reduce(rest_pairs, first_pair, fn p, acc -> {:&&, [], [acc, p]} end)

    result =
      case temp_bindings do
        [] -> chain
        _ -> {:__block__, [], temp_bindings ++ [chain]}
      end

    {result, context}
  end

  @doc """
  Map a single Python comparison operator to its Elixir equivalent.
  """
  @spec pair_ast(map(), Macro.t(), Macro.t()) :: Macro.t()
  def pair_ast(%{"_type" => "Eq"}, l, r), do: {:==, [], [l, r]}
  def pair_ast(%{"_type" => "NotEq"}, l, r), do: {:!=, [], [l, r]}
  def pair_ast(%{"_type" => "Lt"}, l, r), do: {:<, [], [l, r]}
  def pair_ast(%{"_type" => "LtE"}, l, r), do: {:<=, [], [l, r]}
  def pair_ast(%{"_type" => "Gt"}, l, r), do: {:>, [], [l, r]}
  def pair_ast(%{"_type" => "GtE"}, l, r), do: {:>=, [], [l, r]}
  def pair_ast(%{"_type" => "Is"}, l, r), do: {:==, [], [l, r]}
  def pair_ast(%{"_type" => "IsNot"}, l, r), do: {:!=, [], [l, r]}
  def pair_ast(%{"_type" => "In"}, l, r), do: {:py_in, [], [l, r]}
  def pair_ast(%{"_type" => "NotIn"}, l, r), do: {:!, [], [{:py_in, [], [l, r]}]}

  defp build_middle_refs(middles, context) do
    {refs, bindings, context} =
      Enum.reduce(middles, {[], [], context}, fn cmp_node, {refs, bindings, ctx} ->
        {ast, ctx} = Converter.convert(cmp_node, ctx)

        if Trivial.trivial?(cmp_node) do
          {[ast | refs], bindings, ctx}
        else
          {temp_atom, ctx} = Converter.next_temp(ctx)
          temp_ref = {temp_atom, [], nil}
          binding = {:=, [], [temp_ref, ast]}
          {[temp_ref | refs], [binding | bindings], ctx}
        end
      end)

    {Enum.reverse(refs), Enum.reverse(bindings), context}
  end

  defp build_compare_pairs(operands, ops) do
    pairs = Enum.zip(operands, tl(operands))

    Enum.zip(pairs, ops)
    |> Enum.map(fn {{l, r}, op} -> pair_ast(op, l, r) end)
  end
end
