defmodule Pylixir.Nodes.If do
  @moduledoc """
  Lower Python `If` statements. Three shapes:

    * `emit_only/3` — `if x:` with no `else`.
    * `emit_else/4` — `if x:` with `else:`.
    * `emit_cond_chain/4` — `if/elif/elif/.../else` — collapses to one
      `cond` expression rather than nested `if`s.

  Any branch whose body assigns to a variable that's read after the
  `if` must contribute that variable to a "state tuple" that the
  `if`/`cond` expression evaluates to — Elixir's lexical scoping doesn't
  let an `if`'s body leak bindings to its sibling block. The
  `state_tuple_*` helpers + `convert_body_with_acc` build that pattern.

  Cross-section helpers (`convert_test`, `convert_each`, `bind_name`,
  `body_to_block`, `tuple_pattern`) live on `Pylixir.Converter`.
  """

  alias Pylixir.{Converter, LoopAnalysis, Naming}

  @spec emit_only(map(), [map()], Pylixir.Context.t()) ::
          {Macro.t(), Pylixir.Context.t()}
  def emit_only(test, body, context) do
    assigned = if_assigned_vars(body, [])
    {test_ast, context} = Converter.convert_test(test, context)

    if assigned == [] do
      {body_block, context} = convert_body_block(body, context)
      {{:if, [], [test_ast, [do: body_block]]}, context}
    else
      {body_block, context} = convert_body_with_acc(body, assigned, context)
      else_block = state_tuple_value(assigned)
      pattern = state_tuple_pattern(assigned)
      context = Enum.reduce(assigned, context, &Converter.bind_name(&2, &1))

      {{:=, [], [pattern, {:if, [], [test_ast, [do: body_block, else: else_block]]}]}, context}
    end
  end

  @spec emit_else(map(), [map()], [map()], Pylixir.Context.t()) ::
          {Macro.t(), Pylixir.Context.t()}
  def emit_else(test, body, orelse, context) do
    assigned = if_assigned_vars(body, orelse)
    {test_ast, context} = Converter.convert_test(test, context)

    if assigned == [] do
      {body_block, context} = convert_body_block(body, context)
      {else_block, context} = convert_body_block(orelse, context)
      {{:if, [], [test_ast, [do: body_block, else: else_block]]}, context}
    else
      {body_block, context} = convert_body_with_acc(body, assigned, context)
      {else_block, context} = convert_body_with_acc(orelse, assigned, context)
      pattern = state_tuple_pattern(assigned)
      context = Enum.reduce(assigned, context, &Converter.bind_name(&2, &1))

      {{:=, [], [pattern, {:if, [], [test_ast, [do: body_block, else: else_block]]}]}, context}
    end
  end

  @spec emit_cond_chain(map(), [map()], [map()], Pylixir.Context.t()) ::
          {Macro.t(), Pylixir.Context.t()}
  def emit_cond_chain(test, body, orelse, context) do
    assigned = cond_assigned_vars(test, body, orelse)

    if assigned == [] do
      {clauses, terminal_else, context} = collect_cond_chain(test, body, orelse, context, [])

      arrow_clauses =
        Enum.map(Enum.reverse(clauses), fn {t, b} -> {:->, [], [[t], b]} end)

      fallthrough_body = terminal_else || nil
      all_clauses = arrow_clauses ++ [{:->, [], [[true], fallthrough_body]}]

      {{:cond, [], [[do: all_clauses]]}, context}
    else
      {clauses, terminal_else, context} =
        collect_cond_chain_threaded(test, body, orelse, assigned, context, [])

      arrow_clauses =
        Enum.map(Enum.reverse(clauses), fn {t, b} -> {:->, [], [[t], b]} end)

      fallthrough_body = terminal_else || state_tuple_value(assigned)
      all_clauses = arrow_clauses ++ [{:->, [], [[true], fallthrough_body]}]

      pattern = state_tuple_pattern(assigned)
      context = Enum.reduce(assigned, context, &Converter.bind_name(&2, &1))

      {{:=, [], [pattern, {:cond, [], [[do: all_clauses]]}]}, context}
    end
  end

  defp collect_cond_chain(test, body, orelse, context, acc) do
    {test_ast, context} = Converter.convert_test(test, context)
    {body_block, context} = convert_body_block(body, context)
    acc = [{test_ast, body_block} | acc]

    case orelse do
      [] ->
        {acc, nil, context}

      [%{"_type" => "If", "test" => t, "body" => b, "orelse" => o}] ->
        collect_cond_chain(t, b, o, context, acc)

      _ ->
        {else_block, context} = convert_body_block(orelse, context)
        {acc, else_block, context}
    end
  end

  defp collect_cond_chain_threaded(test, body, orelse, assigned, context, acc) do
    {test_ast, context} = Converter.convert_test(test, context)
    {body_block, context} = convert_body_with_acc(body, assigned, context)
    acc = [{test_ast, body_block} | acc]

    case orelse do
      [] ->
        {acc, nil, context}

      [%{"_type" => "If", "test" => t, "body" => b, "orelse" => o}] ->
        collect_cond_chain_threaded(t, b, o, assigned, context, acc)

      _ ->
        {else_block, context} = convert_body_with_acc(orelse, assigned, context)
        {acc, else_block, context}
    end
  end

  # Collect names assigned anywhere in either branch of an If.
  defp if_assigned_vars(body, orelse) do
    body_a = LoopAnalysis.analyze(body).assigned_vars
    else_a = LoopAnalysis.analyze(orelse).assigned_vars

    body_a |> MapSet.union(else_a) |> MapSet.to_list() |> Enum.sort()
  end

  defp cond_assigned_vars(_test, body, orelse) do
    collect_cond_assigned(body, orelse, MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp collect_cond_assigned(body, orelse, acc) do
    acc = MapSet.union(acc, LoopAnalysis.analyze(body).assigned_vars)

    case orelse do
      [%{"_type" => "If", "body" => b, "orelse" => o}] ->
        collect_cond_assigned(b, o, acc)

      stmts ->
        MapSet.union(acc, LoopAnalysis.analyze(stmts).assigned_vars)
    end
  end

  defp convert_body_with_acc(body, assigned, context) do
    {asts, context} = Converter.convert_each(body, context)
    tail = state_tuple_value(assigned)
    {Converter.body_to_block(asts ++ [tail]), context}
  end

  defp state_tuple_value([single]),
    do: {single |> Naming.rewrite() |> String.to_atom(), [], nil}

  defp state_tuple_value(names) do
    refs =
      Enum.map(names, fn n -> {n |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    Converter.tuple_pattern(refs)
  end

  defp state_tuple_pattern(names), do: state_tuple_value(names)

  defp convert_body_block(stmts, context) do
    {asts, context} = Converter.convert_each(stmts, context)
    {Converter.body_to_block(asts), context}
  end
end
