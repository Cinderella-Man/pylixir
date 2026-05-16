defmodule Pylixir.Nodes.Comprehension do
  @moduledoc """
  Lower Python comprehensions (`ListComp`, `SetComp`, `GeneratorExp`,
  `DictComp`) to Elixir's `Enum.map` / `Enum.flat_map` / `Enum.filter`
  pipelines, wrapped in `MapSet.new` / `Map.new` as needed.

  Entry point is `emit/4`. The Converter's four comprehension clauses
  delegate here; everything below is private to the lowering. Cross-node
  helpers (`Converter.convert`, `convert_loop_target`, `convert_test`)
  are reused as-is.
  """

  alias Pylixir.Converter

  @type kind :: :list | :set | :gen | :dict

  @spec emit(kind(), map() | {map(), map()}, [map()], Pylixir.Context.t()) ::
          {Macro.t(), Pylixir.Context.t()}
  def emit(kind, elt_node, generators, context) do
    {pipeline, context} = build_comp(generators, elt_node, kind, context)

    final =
      case kind do
        :list -> pipeline
        :gen -> pipeline
        :set -> {{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], [pipeline]}
        :dict -> {{:., [], [{:__aliases__, [], [:Map]}, :new]}, [], [pipeline]}
      end

    {final, context}
  end

  # Single (last) generator: filter + map.
  defp build_comp([%{"target" => target, "iter" => iter, "ifs" => ifs}], elt_node, kind, context) do
    {iter_ast, context} = Converter.convert(iter, context)
    saved_scopes = context.scopes
    {target_ast, _, context} = Converter.convert_loop_target(target, context)
    {filtered_iter, context} = apply_filter(iter_ast, target_ast, ifs, context)
    {leaf, context} = comp_leaf(elt_node, kind, context)

    pipeline =
      {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [],
       [filtered_iter, {:fn, [], [{:->, [], [[target_ast], leaf]}]}]}

    context = %{context | scopes: saved_scopes}
    {pipeline, context}
  end

  # Multiple generators: flat_map of the rest.
  defp build_comp(
         [%{"target" => target, "iter" => iter, "ifs" => ifs} | rest],
         elt_node,
         kind,
         context
       ) do
    {iter_ast, context} = Converter.convert(iter, context)
    saved_scopes = context.scopes
    {target_ast, _, context} = Converter.convert_loop_target(target, context)
    {filtered_iter, context} = apply_filter(iter_ast, target_ast, ifs, context)
    {inner, context} = build_comp(rest, elt_node, kind, context)

    pipeline =
      {{:., [], [{:__aliases__, [], [:Enum]}, :flat_map]}, [],
       [filtered_iter, {:fn, [], [{:->, [], [[target_ast], inner]}]}]}

    context = %{context | scopes: saved_scopes}
    {pipeline, context}
  end

  defp apply_filter(iter_ast, _target_ast, [], context), do: {iter_ast, context}

  defp apply_filter(iter_ast, target_ast, ifs, context) do
    {if_asts, context} =
      Enum.reduce(ifs, {[], context}, fn cond_node, {acc, ctx} ->
        {test_ast, ctx} = Converter.convert_test(cond_node, ctx)
        {[test_ast | acc], ctx}
      end)

    combined =
      if_asts
      |> Enum.reverse()
      |> Enum.reduce(fn ast, acc -> {:&&, [], [acc, ast]} end)

    filter_call =
      {{:., [], [{:__aliases__, [], [:Enum]}, :filter]}, [],
       [iter_ast, {:fn, [], [{:->, [], [[target_ast], combined]}]}]}

    {filter_call, context}
  end

  defp comp_leaf(elt_node, kind, context) when kind in [:list, :set, :gen] do
    Converter.convert(elt_node, context)
  end

  defp comp_leaf({key_node, value_node}, :dict, context) do
    {k_ast, context} = Converter.convert(key_node, context)
    {v_ast, context} = Converter.convert(value_node, context)
    {{k_ast, v_ast}, context}
  end
end
