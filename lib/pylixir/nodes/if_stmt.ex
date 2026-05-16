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

  # MapSet is `@opaque`; Dialyzer can't trace that values built by
  # `MapSet.new/0` + `LoopAnalysis.analyze(...).assigned_vars` still
  # satisfy the opaque contract through these helpers. The values *are*
  # MapSets at runtime — the warning is a known false positive.
  @dialyzer {:nowarn_function,
             collect_cond_assigned: 3, cond_assigned_vars: 3, if_assigned_vars: 2}

  @spec emit_only(map(), [map()], Pylixir.Context.t()) ::
          {Macro.t(), Pylixir.Context.t()}
  def emit_only(test, body, context) do
    assigned = if_assigned_vars(body, [])
    {test_ast, context} = Converter.convert_test(test, context)

    if assigned == [] do
      {body_block, context} = convert_body_block(body, context)
      {{:if, [], [test_ast, [do: body_block]]}, context}
    else
      pre_if_context = context
      {body_block, context} = convert_body_with_acc(body, assigned, context)
      else_block = state_tuple_value(assigned, pre_if_context)
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
      {body_block, else_block, context} = convert_sibling_branches(body, orelse, context)
      {{:if, [], [test_ast, [do: body_block, else: else_block]]}, context}
    else
      {body_block, else_block, context} =
        convert_sibling_branches_with_acc(body, orelse, assigned, context)

      pattern = state_tuple_pattern(assigned)
      context = Enum.reduce(assigned, context, &Converter.bind_name(&2, &1))

      {{:=, [], [pattern, {:if, [], [test_ast, [do: body_block, else: else_block]]}]}, context}
    end
  end

  # Sibling-branch convention: both branches see the *same* pre-if
  # context's scopes; names bound during the if-branch must NOT be
  # visible while converting the else-branch (in Python the two
  # branches share the surrounding scope, but for code-generation
  # purposes Elixir's lexical scoping means we have to keep their
  # visibility independent during the per-branch walk). Counters and
  # other monotonically-advancing Context fields (`temp_counter`,
  # `while_counter`, `while_helpers`, …) flow through both branches
  # in order — only scopes get reset.
  defp convert_sibling_branches(body, orelse, context) do
    saved_scopes = context.scopes
    {body_block, context} = convert_body_block(body, context)
    context = %{context | scopes: saved_scopes}
    {else_block, context} = convert_body_block(orelse, context)
    {body_block, else_block, context}
  end

  defp convert_sibling_branches_with_acc(body, orelse, assigned, context) do
    saved_scopes = context.scopes
    {body_block, context} = convert_body_with_acc(body, assigned, context)
    context = %{context | scopes: saved_scopes}
    {else_block, context} = convert_body_with_acc(orelse, assigned, context)
    {body_block, else_block, context}
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
      pre_if_context = context

      {clauses, terminal_else, context} =
        collect_cond_chain_threaded(test, body, orelse, assigned, context, [])

      arrow_clauses =
        Enum.map(Enum.reverse(clauses), fn {t, b} -> {:->, [], [[t], b]} end)

      fallthrough_body = terminal_else || state_tuple_value(assigned, pre_if_context)
      all_clauses = arrow_clauses ++ [{:->, [], [[true], fallthrough_body]}]

      pattern = state_tuple_pattern(assigned)
      context = Enum.reduce(assigned, context, &Converter.bind_name(&2, &1))

      {{:=, [], [pattern, {:cond, [], [[do: all_clauses]]}]}, context}
    end
  end

  # Each elif clause and the terminal else are sibling branches —
  # like emit_else, they must NOT see scopes bound during the
  # preceding branches. Save+restore scopes around each branch body.
  defp collect_cond_chain(test, body, orelse, context, acc) do
    {test_ast, context} = Converter.convert_test(test, context)
    saved_scopes = context.scopes
    {body_block, context} = convert_body_block(body, context)
    context = %{context | scopes: saved_scopes}
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
    saved_scopes = context.scopes
    {body_block, context} = convert_body_with_acc(body, assigned, context)
    context = %{context | scopes: saved_scopes}
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
    # Use the post-body context: vars bound during this branch
    # contribute their ref; vars only bound in the *other* branch
    # default to `nil`. Matches Python's "if-without-else makes the
    # var None on the falsy path" semantics.
    tail = state_tuple_value_with_defaults(assigned, context)
    {Converter.body_to_block(asts ++ [tail]), context}
  end

  # Build the tail-position state-tuple value. For each name in
  # `assigned`, emit a ref if the name is bound in `context` (either
  # pre-if or bound by this branch's body); otherwise emit `nil`.
  defp state_tuple_value_with_defaults([single], context) do
    if Converter.name_in_scope?(context, single) do
      {single |> Naming.rewrite() |> String.to_atom(), [], nil}
    else
      nil
    end
  end

  defp state_tuple_value_with_defaults(names, context) do
    refs =
      Enum.map(names, fn n ->
        if Converter.name_in_scope?(context, n) do
          {n |> Naming.rewrite() |> String.to_atom(), [], nil}
        else
          nil
        end
      end)

    Converter.tuple_pattern(refs)
  end

  # Tail-position fallthroughs (`else_block` in emit_only, the
  # implicit no-match arm of a cond chain): no branch ran, so each
  # threaded var defaults to its pre-if binding (if any) or `nil`.
  defp state_tuple_value(assigned, pre_if_context),
    do: state_tuple_value_with_defaults(assigned, pre_if_context)

  # Tuple-pattern for the LHS — must always be the bare-ref shape
  # (Elixir patterns require variables, not `nil` literals as the
  # leftmost position). This is the existing behaviour kept intact.
  defp state_tuple_pattern([single]),
    do: {single |> Naming.rewrite() |> String.to_atom(), [], nil}

  defp state_tuple_pattern(names) do
    refs =
      Enum.map(names, fn n -> {n |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    Converter.tuple_pattern(refs)
  end

  defp convert_body_block(stmts, context) do
    {asts, context} = Converter.convert_each(stmts, context)
    {Converter.body_to_block(asts), context}
  end
end
