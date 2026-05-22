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

  alias Pylixir.{AST.Trivial, Converter, TypeInfer}

  @spec emit(map(), [map()], [map()], Pylixir.Context.t()) ::
          {Macro.t(), Pylixir.Context.t()}
  def emit(left, [single_op], comparators, context) do
    [right_node] = comparators
    lt = TypeInfer.infer_expr(left, context)
    rt = TypeInfer.infer_expr(right_node, context)
    {left_ast, context} = Converter.convert(left, context)
    {right_ast, context} = Converter.convert(right_node, context)
    {pair_ast(single_op, left_ast, right_ast, lt, rt), context}
  end

  def emit(left, ops, comparators, context) do
    lt = TypeInfer.infer_expr(left, context)
    {left_ast, context} = Converter.convert(left, context)
    {middles, last} = Enum.split(comparators, length(comparators) - 1)

    middle_types = Enum.map(middles, &TypeInfer.infer_expr(&1, context))
    {middle_refs, temp_bindings, context} = build_middle_refs(middles, context)

    last_node = hd(last)
    last_type = TypeInfer.infer_expr(last_node, context)
    {last_ast, context} = Converter.convert(last_node, context)

    operand_asts = [left_ast | middle_refs] ++ [last_ast]
    operand_types = [lt | middle_types] ++ [last_type]
    pairs = build_compare_pairs(operand_asts, operand_types, ops)
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

  The 5-arg form takes the operand types and specializes `In` / `NotIn`
  to container-specific operators when the right-hand type is known
  (decision PR 5). Equality / ordering operators don't currently
  specialize — the polymorphic Elixir operators already match Python
  semantics for the typed cases.
  """
  @spec pair_ast(map(), Macro.t(), Macro.t()) :: Macro.t()
  def pair_ast(op, l, r), do: pair_ast(op, l, r, :any, :any)

  @spec pair_ast(map(), Macro.t(), Macro.t(), TypeInfer.t(), TypeInfer.t()) :: Macro.t()
  def pair_ast(%{"_type" => "Eq"}, l, r, lt, rt) do
    if alist_or_pvec?(lt) or alist_or_pvec?(rt) do
      # An alist/pvec is a tagged tuple at runtime; raw `==` against a
      # plain list would always be false. `py_eq` normalizes the
      # tagged side(s) first. (Lets AlistAnalysis keep a list frozen
      # even when it's compared with `==` — eval-corpus seed_19498
      # `if a == sorted_a:`.)
      {:py_eq, [], [l, r]}
    else
      {:==, [], [l, r]}
    end
  end

  def pair_ast(%{"_type" => "NotEq"}, l, r, lt, rt) do
    if alist_or_pvec?(lt) or alist_or_pvec?(rt) do
      {:!, [], [{:py_eq, [], [l, r]}]}
    else
      {:!=, [], [l, r]}
    end
  end
  def pair_ast(%{"_type" => "Lt"}, l, r, lt, rt), do: order_cmp(:<, :py_lt, l, r, lt, rt)
  def pair_ast(%{"_type" => "LtE"}, l, r, lt, rt), do: order_cmp(:<=, :py_le, l, r, lt, rt)
  def pair_ast(%{"_type" => "Gt"}, l, r, lt, rt), do: order_cmp(:>, :py_gt, l, r, lt, rt)
  def pair_ast(%{"_type" => "GtE"}, l, r, lt, rt), do: order_cmp(:>=, :py_ge, l, r, lt, rt)
  def pair_ast(%{"_type" => "Is"}, l, r, _lt, _rt), do: {:==, [], [l, r]}
  def pair_ast(%{"_type" => "IsNot"}, l, r, _lt, _rt), do: {:!=, [], [l, r]}

  def pair_ast(%{"_type" => "In"}, l, r, lt, rt), do: in_emit(l, r, lt, rt)

  def pair_ast(%{"_type" => "NotIn"}, l, r, lt, rt) do
    {:!, [], [in_emit(l, r, lt, rt)]}
  end

  defp alist_or_pvec?({:py_alist, _}), do: true
  defp alist_or_pvec?({:py_pvec, _}), do: true
  defp alist_or_pvec?(_), do: false

  # Ordering comparison: native `<`/`<=`/`>`/`>=` when both operand types
  # are statically known (cannot be nil), else a nil-coercing helper so a
  # `defaultdict`/`Counter` miss (`nil`) compares as 0 rather than sorting
  # above every number (eval-corpus seed_5737, `Counter(s)[c] < n`).
  defp order_cmp(native_op, helper, l, r, lt, rt) do
    if maybe_nil?(lt) or maybe_nil?(rt) do
      {helper, [], [l, r]}
    else
      {native_op, [], [l, r]}
    end
  end

  defp maybe_nil?(:any), do: true
  defp maybe_nil?(_), do: false

  defp in_emit(l, r, lt, rt) do
    cond do
      # String-in-string: `needle in haystack` → String.contains?(haystack, needle).
      # Requires BOTH sides to be strings — Python `"a" in 1` would TypeError;
      # in Elixir, String.contains? requires both args to be binaries.
      TypeInfer.is_str?(lt) and TypeInfer.is_str?(rt) ->
        {{:., [], [{:__aliases__, [], [:String]}, :contains?]}, [], [r, l]}

      TypeInfer.is_list?(rt) ->
        {:in, [], [l, r]}

      TypeInfer.is_set?(rt) ->
        {{:., [], [{:__aliases__, [], [:MapSet]}, :member?]}, [], [r, l]}

      TypeInfer.is_dict?(rt) ->
        {{:., [], [{:__aliases__, [], [:Map]}, :has_key?]}, [], [r, l]}

      true ->
        {:py_in, [], [l, r]}
    end
  end

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

  defp build_compare_pairs(operands, types, ops) do
    pairs = Enum.zip(operands, tl(operands))
    type_pairs = Enum.zip(types, tl(types))

    Enum.zip([pairs, type_pairs, ops])
    |> Enum.map(fn {{l, r}, {lt, rt}, op} -> pair_ast(op, l, r, lt, rt) end)
  end
end
