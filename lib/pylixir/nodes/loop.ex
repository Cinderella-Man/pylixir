defmodule Pylixir.Nodes.Loop do
  @moduledoc """
  Lower Python loop constructs (`While`, `For`) plus `Break` / `Continue`.

  ## Strategy

  Pylixir lowers loops in one of three shapes depending on what the
  body assigns (the "threaded" set) and whether `break`/`continue` are
  present (the "flow" tuple):

    * **`Enum.each`** — no threaded vars; for-loops over an iterable
      with no in-loop reassignments.
    * **`Enum.reduce`** — one or more threaded vars; the for-loop body
      becomes an accumulator-returning fn.
    * **Tail-recursive helper `defp while_<n>`** — every `while` loop.
      Lifted onto the surrounding module via `Context.while_helpers`.

  ## Throw protocol

  `Break` throws `{:pylixir_break, payload}`; `Continue` throws
  `{:pylixir_continue, payload}`. The enclosing loop catches both
  shapes — `maybe_break_*` / `maybe_continue_*` wrap the relevant
  Elixir expression in `try/catch` *only when* the body actually
  contains the flow node (see `loop_flow/1`'s same-loop walker).

  Cross-section helpers (`bind_name`, `body_to_block`, `tuple_pattern`,
  `convert_each`, `convert_test`, `convert_loop_target`, `var_bound?`)
  live on `Pylixir.Converter`.
  """

  alias Pylixir.{
    AST.Walk,
    Context,
    ControlFlow,
    Converter,
    LoopAnalysis,
    Naming,
    TypeInfer,
    UnsupportedNodeError
  }

  # MapSet is `@opaque`; Dialyzer can't trace that the value built from
  # `Walk.walk_scope/3` (started with `MapSet.new/0`) still satisfies
  # the opaque contract by the time it reaches `MapSet.union/2`. Runtime
  # type is correct — this is a known false positive.
  @dialyzer {:nowarn_function, emit_while: 2}

  # --- Public entry points -----------------------------------------------

  @spec while_(map(), Context.t()) :: {Macro.t(), Context.t()}
  def while_(%{"test" => test, "body" => body} = node, context) do
    orelse = Map.get(node, "orelse", [])

    if orelse == [] do
      emit_while(%{"test" => test, "body" => body}, context)
    else
      emit_while_else(test, body, orelse, context)
    end
  end

  @spec for_(map(), Context.t()) :: {Macro.t(), Context.t()}
  def for_(%{"target" => target, "iter" => iter, "body" => body} = node, context) do
    orelse = Map.get(node, "orelse", [])

    if orelse == [] do
      emit_for(%{"target" => target, "iter" => iter, "body" => body}, context)
    else
      emit_for_else(target, iter, body, orelse, context)
    end
  end

  @spec break_(map(), Context.t()) :: {Macro.t(), Context.t()}
  def break_(node, context) do
    case context.loop_break_payload do
      nil ->
        raise UnsupportedNodeError,
          node_type: "Break",
          hint: "`break` outside a loop is not supported (and is a SyntaxError in Python)",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      payload_ast ->
        {ControlFlow.throw_break(payload_ast), context}
    end
  end

  @spec continue_(map(), Context.t()) :: {Macro.t(), Context.t()}
  def continue_(node, context) do
    case context.loop_break_payload do
      nil ->
        raise UnsupportedNodeError,
          node_type: "Continue",
          hint: "`continue` outside a loop is not supported (and is a SyntaxError in Python)",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      payload_ast ->
        {ControlFlow.throw_continue(payload_ast), context}
    end
  end

  # --- While emission (T18) ----------------------------------------------

  defp emit_while(%{"test" => test, "body" => body}, context) do
    n = context.while_counter
    fn_name = String.to_atom("while_#{n}")
    context = %{context | while_counter: n + 1}

    pre_loop_context = context
    analysis = LoopAnalysis.analyze(body)
    threaded = analysis.assigned_vars |> MapSet.to_list() |> Enum.sort()
    threaded_set = MapSet.new(threaded)

    # Read-only vars: referenced inside body, NOT threaded, AND bound in
    # the outer scope. These pass through the recursive helper unchanged
    # (RFC §10.5).
    referenced_in_test =
      Walk.walk_scope(test, MapSet.new(), fn
        %{"_type" => "Name", "id" => id}, acc -> MapSet.put(acc, id)
        _, acc -> acc
      end)

    # `read_only` carries through the extracted `defp while_N` helper's
    # parameter list any names the body reads but doesn't reassign.
    # Two source-of-truth checks: bound in surrounding scope (regular
    # local), OR a demoted top-level def (its closure binding lives in
    # py_main but the call site we'll emit IS inside that py_main, so
    # threading the closure ref as a param is safe).
    read_only =
      analysis.referenced_vars
      |> MapSet.union(referenced_in_test)
      |> MapSet.difference(threaded_set)
      |> MapSet.to_list()
      |> Enum.filter(fn v ->
        Converter.var_bound?(pre_loop_context, v) or
          MapSet.member?(pre_loop_context.demoted_functions, v)
      end)
      |> Enum.sort()

    {payload_ast, _refs} = build_acc_refs(threaded)
    flow = loop_flow(body)

    saved_payload = context.loop_break_payload
    context = %{context | loop_break_payload: payload_ast}
    {test_ast, context} = Converter.convert_test(test, context)
    {body_asts, context} = Converter.convert_each(body, context)
    context = %{context | loop_break_payload: saved_payload}

    threaded_refs =
      Enum.map(threaded, fn v -> {v |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    read_only_refs =
      Enum.map(read_only, fn v -> {v |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    param_refs = threaded_refs ++ read_only_refs
    state_value = state_value_ast(threaded, threaded_refs)
    initial_args = Enum.map(threaded ++ read_only, &initial_ref(&1, pre_loop_context))

    recurse_call = {fn_name, [], param_refs}
    body_with_recurse = Converter.body_to_block(body_asts ++ [recurse_call])
    inner_body = maybe_continue_while(body_with_recurse, payload_ast, recurse_call, elem(flow, 1))

    cond_ast =
      {:cond, [],
       [
         [
           do: [
             {:->, [], [[test_ast], inner_body]},
             {:->, [], [[true], state_value]}
           ]
         ]
       ]}

    defp_ast =
      {:defp, [],
       [
         {fn_name, [], param_refs},
         [do: cond_ast]
       ]}

    context = %{context | while_helpers: context.while_helpers ++ [defp_ast]}

    caller_call = {fn_name, [], initial_args}
    wrapped_call = maybe_break_reduce(caller_call, payload_ast, elem(flow, 0))

    context =
      Enum.reduce(threaded, context, fn v, ctx -> Converter.bind_name(ctx, v) end)

    final_ast =
      case threaded do
        [] -> wrapped_call
        _ -> {:=, [], [payload_ast, wrapped_call]}
      end

    {final_ast, context}
  end

  defp state_value_ast([], _refs), do: :ok
  defp state_value_ast([_single], [ref]), do: ref
  defp state_value_ast(_, refs), do: Converter.tuple_pattern(refs)

  # --- While/else emission (Python's `while cond: ... else: ...`) -------
  #
  # Semantics: the `else` block runs after the loop ONLY when the loop
  # exited because `cond` became false — NOT when it exited via
  # `break`. Strategy mirrors `emit_for_else`: build the same recursive
  # `while_N` helper as `emit_while`, but wrap the caller call in a
  # try that returns `{state, broke?}`. Bind the threaded vars from
  # `state`, then `unless broke?, do: else_block`.
  defp emit_while_else(test, body, orelse, context) do
    saved_scopes = context.scopes
    {while_ast, threaded, context} = build_while_helper(test, body, context)

    broke_var = {:pylixir_broke?, [], nil}
    state_var = {:pylixir_while_else_state, [], nil}

    try_ast =
      {:try, [],
       [
         [
           do: {:__block__, [], [{:=, [], [state_var, while_ast]}, {state_var, false}]},
           catch: [
             {:->, [],
              [
                [:throw, {:pylixir_break, {:payload, [], nil}}],
                {{:payload, [], nil}, true}
              ]}
           ]
         ]
       ]}

    bind_state = {:=, [], [{state_var, broke_var}, try_ast]}

    threaded_refs =
      Enum.map(threaded, fn v -> {v |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    bind_threaded =
      case threaded_refs do
        [] -> nil
        [single] -> {:=, [], [single, state_var]}
        many -> {:=, [], [Converter.tuple_pattern(many), state_var]}
      end

    context = %{context | scopes: saved_scopes}
    context = Enum.reduce(threaded, context, fn v, ctx -> Converter.bind_name(ctx, v) end)

    # The else block can assign its own names that must escape the
    # `if` expression's scope. Collect them, then arrange both `if`
    # branches to return a tuple of those names: the run-the-else
    # branch evaluates the user's block then yields the tuple of the
    # post-block values; the skip-else branch yields the same tuple
    # of pre-else values (or `nil` for names not yet in scope). Bind
    # the tuple in the outer context. Mirrors the IfStmt threading
    # pattern.
    pre_else_context = context

    orelse_assigned =
      orelse
      |> LoopAnalysis.analyze()
      |> Map.get(:assigned_vars)
      |> MapSet.to_list()
      |> Enum.sort()

    {else_asts, context} = Converter.convert_each(orelse, context)
    else_block = Converter.body_to_block(else_asts)

    {cond_else, context} =
      case orelse_assigned do
        [] ->
          {{:if, [], [{:!, [], [broke_var]}, [do: else_block, else: nil]]}, context}

        names ->
          refs =
            Enum.map(names, fn v -> {v |> Naming.rewrite() |> String.to_atom(), [], nil} end)

          pre_values =
            Enum.map(names, fn v ->
              if Converter.var_bound?(pre_else_context, v) do
                {v |> Naming.rewrite() |> String.to_atom(), [], nil}
              else
                nil
              end
            end)

          do_tail = tuple_or_single(refs)
          else_tail = tuple_or_single(pre_values)
          do_body = Converter.body_to_block([else_block, do_tail])
          pattern = tuple_or_single(refs)

          if_expr =
            {:if, [], [{:!, [], [broke_var]}, [do: do_body, else: else_tail]]}

          context = Enum.reduce(names, context, fn v, ctx -> Converter.bind_name(ctx, v) end)
          {{:=, [], [pattern, if_expr]}, context}
      end

    pieces = Enum.reject([bind_state, bind_threaded, cond_else], &is_nil/1)
    {Converter.body_to_block(pieces), context}
  end

  defp tuple_or_single([single]), do: single
  defp tuple_or_single(many), do: Converter.tuple_pattern(many)

  # Build the `defp while_N` helper + return the raw caller call (the
  # value the helper returns when cond goes false — without any
  # break-catching wrap). `emit_while_else` then wraps that itself.
  # Returns `{caller_call, threaded_names, context_with_helper_in_helpers}`.
  defp build_while_helper(test, body, context) do
    n = context.while_counter
    fn_name = String.to_atom("while_#{n}")
    context = %{context | while_counter: n + 1}

    pre_loop_context = context
    analysis = LoopAnalysis.analyze(body)
    threaded = analysis.assigned_vars |> MapSet.to_list() |> Enum.sort()
    threaded_set = MapSet.new(threaded)

    referenced_in_test =
      Walk.walk_scope(test, MapSet.new(), fn
        %{"_type" => "Name", "id" => id}, acc -> MapSet.put(acc, id)
        _, acc -> acc
      end)

    # `read_only` carries through the extracted `defp while_N` helper's
    # parameter list any names the body reads but doesn't reassign.
    # Two source-of-truth checks: bound in surrounding scope (regular
    # local), OR a demoted top-level def (its closure binding lives in
    # py_main but the call site we'll emit IS inside that py_main, so
    # threading the closure ref as a param is safe).
    read_only =
      analysis.referenced_vars
      |> MapSet.union(referenced_in_test)
      |> MapSet.difference(threaded_set)
      |> MapSet.to_list()
      |> Enum.filter(fn v ->
        Converter.var_bound?(pre_loop_context, v) or
          MapSet.member?(pre_loop_context.demoted_functions, v)
      end)
      |> Enum.sort()

    {payload_ast, _refs} = build_acc_refs(threaded)
    flow = loop_flow(body)

    saved_payload = context.loop_break_payload
    context = %{context | loop_break_payload: payload_ast}
    {test_ast, context} = Converter.convert_test(test, context)
    {body_asts, context} = Converter.convert_each(body, context)
    context = %{context | loop_break_payload: saved_payload}

    threaded_refs =
      Enum.map(threaded, fn v -> {v |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    read_only_refs =
      Enum.map(read_only, fn v -> {v |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    param_refs = threaded_refs ++ read_only_refs
    state_value = state_value_ast(threaded, threaded_refs)
    initial_args = Enum.map(threaded ++ read_only, &initial_ref(&1, pre_loop_context))

    recurse_call = {fn_name, [], param_refs}
    body_with_recurse = Converter.body_to_block(body_asts ++ [recurse_call])
    inner_body = maybe_continue_while(body_with_recurse, payload_ast, recurse_call, elem(flow, 1))

    cond_ast =
      {:cond, [],
       [
         [
           do: [
             {:->, [], [[test_ast], inner_body]},
             {:->, [], [[true], state_value]}
           ]
         ]
       ]}

    defp_ast =
      {:defp, [],
       [
         {fn_name, [], param_refs},
         [do: cond_ast]
       ]}

    context = %{context | while_helpers: context.while_helpers ++ [defp_ast]}

    caller_call = {fn_name, [], initial_args}
    {caller_call, threaded, context}
  end

  # While-specific continue: catch arm calls the recursive helper with the
  # captured state (post-body-so-far values), so continue advances rather
  # than spinning with pre-iteration values.
  defp maybe_continue_while(body_block, _payload_ast, _recurse_call, false), do: body_block

  defp maybe_continue_while(body_block, payload_ast, recurse_call, true) do
    catch_clause = ControlFlow.catch_continue(payload_ast, recurse_call)
    {:try, [], [[do: body_block, catch: [catch_clause]]]}
  end

  # --- For/else emission (Python's `for ... else: ...`) ------------------

  # The `else` clause runs after the loop body **only** if the loop
  # completed without hitting `break`. Strategy: produce the same
  # accumulator we'd normally emit, but wrap the reduce in a try
  # that returns `{value, broke?}` — `{result, false}` on normal
  # completion, `{payload, true}` on break. Then conditionally run
  # the else block. Falls through to the standard emit_for paths for
  # threading/binding so we don't duplicate the for-loop machinery.
  defp emit_for_else(target, iter, body, orelse, context) do
    saved_scopes = context.scopes
    pre_loop_context = context
    saved_types = context.types

    iter_type = TypeInfer.infer_expr(iter, context)
    {iter_ast, context} = Converter.convert(iter, context)
    iter_ast = TypeInfer.coerce_iter(iter_ast, iter_type)
    iter_ast = Converter.elide_range_to_list(iter_ast)

    elem_t = TypeInfer.elem_of(iter_type)

    {target_ast, target_names, context} =
      Converter.convert_loop_target(target, context, elem_t)

    context = TypeInfer.bind_pattern(target, elem_t, context)

    analysis = LoopAnalysis.analyze(body)

    threaded =
      analysis.assigned_vars
      |> MapSet.difference(MapSet.new(target_names))
      |> MapSet.to_list()
      |> Enum.sort()

    {payload_ast, acc_refs} = build_acc_refs(threaded)
    saved = context.loop_break_payload
    context = %{context | loop_break_payload: payload_ast}
    {body_asts, context} = Converter.convert_each(body, context)
    context = %{context | loop_break_payload: saved}

    {_has_break?, has_continue?} = loop_flow(body)

    {reduce_ast, threaded_bind_pattern} =
      build_else_reduce(
        threaded,
        acc_refs,
        iter_ast,
        target_ast,
        body_asts,
        pre_loop_context,
        has_continue?
      )

    broke_var = {:pylixir_broke?, [], nil}
    state_var = unique_state_var()

    # try { reduce; {state, false} } catch :throw, {:pylixir_break, p} -> {p, true} end
    try_ast = build_else_try(reduce_ast, state_var, broke_var)

    # Bind {state, broke?} = <try> ; threaded = state (destructure if tuple)
    bind_state =
      {:=, [], [{state_var, broke_var}, try_ast]}

    bind_threaded =
      case threaded do
        [] -> nil
        [_single] -> {:=, [], [threaded_bind_pattern, state_var]}
        _multi -> {:=, [], [threaded_bind_pattern, state_var]}
      end

    # Restore scopes / types; re-bind threaded vars for the post-loop env.
    context = %{context | scopes: saved_scopes, types: saved_types}
    context = Enum.reduce(threaded, context, fn v, ctx -> Converter.bind_name(ctx, v) end)

    # Convert else body in the post-loop scope (sees threaded vars).
    {else_asts, context} = Converter.convert_each(orelse, context)
    else_block = Converter.body_to_block(else_asts)

    # unless broke?, do: else_block  — emit as `if !broke?, do: ..., else: nil`.
    cond_else =
      {:if, [],
       [
         {:!, [], [broke_var]},
         [do: else_block, else: nil]
       ]}

    pieces = Enum.reject([bind_state, bind_threaded, cond_else], &is_nil/1)
    {Converter.body_to_block(pieces), context}
  end

  # Build the reduce/each call we wrap in the try. Mirrors the four
  # cases in emit_for, but the "normal completion" value we wrap into
  # the {state, false} tuple is the threaded accumulator (or :ok when
  # no threading).
  defp build_else_reduce([], _refs, iter_ast, target_ast, body_asts, _pre_ctx, has_continue?) do
    body_block = Converter.body_to_block(body_asts)
    body_with_continue = maybe_continue_each(body_block, has_continue?)
    fn_ast = {:fn, [], [{:->, [], [[target_ast], body_with_continue]}]}
    reduce = {{:., [], [{:__aliases__, [], [:Enum]}, :each]}, [], [iter_ast, fn_ast]}
    {reduce, nil}
  end

  defp build_else_reduce([var], _refs, iter_ast, target_ast, body_asts, pre_ctx, has_continue?) do
    acc_ref = {var |> Naming.rewrite() |> String.to_atom(), [], nil}
    initial = initial_ref(var, pre_ctx)

    inner_body = Converter.body_to_block(body_asts ++ [acc_ref])
    inner_body = maybe_continue_iter(inner_body, acc_ref, has_continue?)
    fn_ast = {:fn, [], [{:->, [], [[target_ast, acc_ref], inner_body]}]}
    reduce = {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [iter_ast, initial, fn_ast]}
    {reduce, acc_ref}
  end

  defp build_else_reduce(vars, refs, iter_ast, target_ast, body_asts, pre_ctx, has_continue?) do
    acc_pattern = Converter.tuple_pattern(refs)
    initial = Converter.tuple_pattern(Enum.map(vars, &initial_ref(&1, pre_ctx)))

    inner_body = Converter.body_to_block(body_asts ++ [acc_pattern])
    inner_body = maybe_continue_iter(inner_body, acc_pattern, has_continue?)
    fn_ast = {:fn, [], [{:->, [], [[target_ast, acc_pattern], inner_body]}]}
    reduce = {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [iter_ast, initial, fn_ast]}
    {reduce, acc_pattern}
  end

  defp build_else_try(reduce_ast, state_var, _broke_var) do
    normal = {:__block__, [], [reduce_ast, {state_var, false}]}

    # Replace the reduce's tail with `{state_var, false}` instead — we
    # need the reduce *result* to be the state. Simpler: bind the
    # reduce result to state_var then yield {state_var, false}.
    do_block =
      {:__block__, [], [{:=, [], [state_var, reduce_ast]}, {state_var, false}]}

    catch_clause =
      {:->, [], [[:throw, {:pylixir_break, {:payload, [], nil}}], {{:payload, [], nil}, true}]}

    _ = normal
    {:try, [], [[do: do_block, catch: [catch_clause]]]}
  end

  defp unique_state_var, do: {:pylixir_for_else_state, [], nil}

  # --- For emission (T16b + T17) -----------------------------------------

  defp emit_for(%{"target" => target, "iter" => iter, "body" => body}, context) do
    pre_loop_context = context

    iter_type = TypeInfer.infer_expr(iter, context)
    {iter_ast, context} = Converter.convert(iter, context)
    iter_ast = TypeInfer.coerce_iter(iter_ast, iter_type)
    iter_ast = Converter.elide_range_to_list(iter_ast)

    # Save scopes BEFORE convert_loop_target (which binds the target)
    # so we can drop the target binding after the loop. Pylixir's
    # for-loop emission uses `Enum.each`/`Enum.reduce` with the target
    # as a callback parameter — the target isn't visible after the
    # callback, so the context-level binding mustn't outlive the loop
    # either. Body-assigned threaded vars get re-bound below.
    saved_scopes = context.scopes
    saved_types = context.types

    elem_t = TypeInfer.elem_of(iter_type)

    {target_ast, target_names, context} =
      Converter.convert_loop_target(target, context, elem_t)

    # PR 10 — bind the for-target's type via `elem_of(iter_type)` so the
    # body's converter sees `x: elem_t`. `Pattern` binding handles
    # destructure (`for i, x in enumerate(xs)`).
    context = TypeInfer.bind_pattern(target, elem_t, context)

    analysis = LoopAnalysis.analyze(body)

    threaded =
      analysis.assigned_vars
      |> MapSet.difference(MapSet.new(target_names))
      |> MapSet.to_list()
      |> Enum.sort()

    flow = loop_flow(body)

    {payload_ast, acc_refs} = build_acc_refs(threaded)
    saved = context.loop_break_payload
    context = %{context | loop_break_payload: payload_ast}
    {body_asts, context} = Converter.convert_each(body, context)
    context = %{context | loop_break_payload: saved}
    context = %{context | types: saved_types}

    # In-place element-mutation rebuild (T1+): when the loop mutates its
    # target in place, the source must be rebuilt + rebound rather than
    # iterated with `Enum.each` (which discards the mutation). `:none`
    # ⇒ today's exact codegen (no regression).
    rebuild = classify_rebuild(iter, target, body, analysis, threaded, flow, elem_t)

    {result_ast, context} =
      case rebuild do
        {:map, iter_name} ->
          emit_for_map(iter_ast, target_ast, body_asts, iter_name, context)

        :none ->
          case {threaded, flow} do
            {[], _} ->
              emit_for_each(iter_ast, target_ast, body_asts, flow, context)

            {[single], _} ->
              emit_for_reduce_single(
                iter_ast,
                target_ast,
                single,
                body_asts,
                pre_loop_context,
                flow,
                context
              )

            {_multi, _} ->
              emit_for_reduce_tuple(
                iter_ast,
                target_ast,
                threaded,
                acc_refs,
                body_asts,
                pre_loop_context,
                flow,
                context
              )
          end
      end

    # Restore scopes — drops target binding AND any body-locals — then
    # re-bind the threaded vars (threaded through the accumulator) plus,
    # for a rebuild variant, the rebound iterable name (already in scope
    # from before the loop; bind_name is idempotent).
    rebind_names =
      case rebuild do
        {:map, iter_name} -> [iter_name | threaded]
        :none -> threaded
      end

    context = %{context | scopes: saved_scopes}
    context = Enum.reduce(rebind_names, context, fn v, ctx -> Converter.bind_name(ctx, v) end)

    {result_ast, context}
  end

  # --- In-place element-mutation rebuild (T1+) ---------------------------

  # Decide whether (and how) to rebuild+rebind the iterable so an in-place
  # mutation of the loop target propagates back to the source. Returns the
  # rebuild variant tag or `:none` (⇒ unchanged existing codegen).
  #
  # Shared gates: iter is a bare Name NOT itself assigned in the body
  # (blocks mutate-while-iterating / threading-vs-rebind collisions);
  # `orelse` is excluded structurally (emit_for only runs when orelse==[]).
  #
  # T1 gate: single bare-Name target, no break/continue, no threaded vars,
  # and the (type-aware) predicate is TRUE for the target.
  defp classify_rebuild(iter, target, body, analysis, threaded, flow, elem_t) do
    with %{"_type" => "Name", "id" => iter_name} <- iter,
         false <- MapSet.member?(analysis.assigned_vars, iter_name),
         %{"_type" => "Name", "id" => tname} <- target,
         {false, false} <- flow,
         [] <- threaded,
         true <- LoopAnalysis.target_in_place_mutated?(tname, body, elem_t) do
      {:map, iter_name}
    else
      _ -> :none
    end
  end

  # T1 emit: `iter_name = Enum.map(iter, fn target -> body; target end)`.
  # The body's last value is the (mutated) target; collecting it rebuilds
  # the source, and the rebind makes the mutation visible after the loop.
  defp emit_for_map(iter_ast, target_ast, body_asts, iter_name, context) do
    inner_body = Converter.body_to_block(body_asts ++ [target_ast])
    fn_ast = {:fn, [], [{:->, [], [[target_ast], inner_body]}]}
    map_call = {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [], [iter_ast, fn_ast]}
    iter_ref = {iter_name |> Naming.rewrite() |> String.to_atom(), [], nil}
    {{:=, [], [iter_ref, map_call]}, context}
  end

  # --- Shared loop machinery ---------------------------------------------

  # Tuple {has_break?, has_continue?} restricted to break/continue at THIS
  # loop's level — does not descend into nested For/While/Function/etc.
  defp loop_flow(body) do
    Enum.reduce(body, {false, false}, fn node, {b, c} ->
      same_loop_walk(node, {b, c}, fn
        %{"_type" => "Break"}, {_, cc} -> {true, cc}
        %{"_type" => "Continue"}, {bb, _} -> {bb, true}
        _, acc -> acc
      end)
    end)
  end

  defp same_loop_walk(%{"_type" => type} = node, acc, fun) do
    acc = fun.(node, acc)

    cond do
      # A nested loop's `else` clause runs once after the nested loop
      # finishes — outside its iteration — so a `break`/`continue` there
      # targets THIS loop, not the nested one. Descend into the nested
      # loop's `orelse` only; its body/iter/target belong to it.
      type in ~w(For AsyncFor While) ->
        same_loop_walk(Map.get(node, "orelse", []), acc, fun)

      type in ~w(FunctionDef AsyncFunctionDef Lambda ClassDef
                 ListComp SetComp DictComp GeneratorExp) ->
        acc

      true ->
        node
        |> Map.delete("_type")
        |> Enum.reduce(acc, fn {_k, v}, a -> same_loop_walk(v, a, fun) end)
    end
  end

  defp same_loop_walk(list, acc, fun) when is_list(list) do
    Enum.reduce(list, acc, fn item, a -> same_loop_walk(item, a, fun) end)
  end

  defp same_loop_walk(_, acc, _fun), do: acc

  defp build_acc_refs([]), do: {:pylixir_each, []}

  defp build_acc_refs([single]) do
    ref = {single |> Naming.rewrite() |> String.to_atom(), [], nil}
    {ref, [ref]}
  end

  defp build_acc_refs(vars) do
    refs =
      Enum.map(vars, fn v -> {v |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    {Converter.tuple_pattern(refs), refs}
  end

  defp emit_for_each(iter_ast, target_ast, body_asts, {has_break?, has_continue?}, context) do
    body_block = Converter.body_to_block(body_asts)
    body_with_continue = maybe_continue_each(body_block, has_continue?)
    fn_ast = {:fn, [], [{:->, [], [[target_ast], body_with_continue]}]}
    each_call = {{:., [], [{:__aliases__, [], [:Enum]}, :each]}, [], [iter_ast, fn_ast]}
    wrapped = maybe_break_each(each_call, has_break?)
    {wrapped, context}
  end

  defp maybe_continue_each(body_block, false), do: body_block

  defp maybe_continue_each(body_block, true) do
    catch_clause = ControlFlow.catch_continue({:_, [], nil}, :ok)
    {:try, [], [[do: body_block, catch: [catch_clause]]]}
  end

  defp maybe_break_each(call, false), do: call

  defp maybe_break_each(call, true) do
    catch_clause = ControlFlow.catch_break({:_, [], nil}, :ok)
    {:try, [], [[do: call, catch: [catch_clause]]]}
  end

  defp emit_for_reduce_single(iter_ast, target_ast, var, body_asts, pre_ctx, flow, context) do
    acc_inlineable? = pvec_accumulator_inlinable?(var, body_asts, context)
    ro_pvec_names = readonly_pvec_names_in_body(body_asts, var, context)

    cond do
      acc_inlineable? or ro_pvec_names != [] ->
        emit_for_reduce_single_pvec_specialized(
          iter_ast,
          target_ast,
          var,
          body_asts,
          pre_ctx,
          flow,
          context,
          acc_inlineable?,
          ro_pvec_names
        )

      true ->
        emit_for_reduce_single_generic(
          iter_ast,
          target_ast,
          var,
          body_asts,
          pre_ctx,
          flow,
          context
        )
    end
  end

  defp emit_for_reduce_single_generic(
         iter_ast,
         target_ast,
         var,
         body_asts,
         pre_ctx,
         flow,
         context
       ) do
    acc_ref = {var |> Naming.rewrite() |> String.to_atom(), [], nil}
    initial = initial_ref(var, pre_ctx)

    inner_body = Converter.body_to_block(body_asts ++ [acc_ref])
    inner_body = maybe_continue_iter(inner_body, acc_ref, elem(flow, 1))

    fn_ast = {:fn, [], [{:->, [], [[target_ast, acc_ref], inner_body]}]}

    reduce =
      {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [iter_ast, initial, fn_ast]}

    rhs = maybe_break_reduce(reduce, acc_ref, elem(flow, 0))
    context = Converter.bind_name(context, var)
    {{:=, [], [acc_ref, rhs]}, context}
  end

  # Pvec specialization for a single-accumulator reduce. Handles two
  # independent rewrites; either or both may fire:
  #
  #   1. Accumulator write-spec (`acc_inlineable?`): when the
  #      accumulator itself is `{:py_pvec, _}` and the body uses it
  #      only via `py_getitem(acc, k)` / `py_setitem(acc, k, v)`,
  #      unwrap before the loop, thread the raw `:array` through the
  #      reduce via `py_pvec_arr_set/get`, rewrap after. Saves the
  #      `{:py_pvec, _}` tag-wrap allocation per iter.
  #
  #   2. Read-only pvec spec (`ro_pvec_names`): for each pvec-typed
  #      name (other than the accumulator) used in the body via
  #      `py_getitem(name, _)` only — no writes, no bare references —
  #      unwrap once before the loop and rewrite reads to the raw
  #      `py_pvec_arr_get/2` helper. No rewrap needed; the wrapped
  #      `name` is still in scope outside the loop and is unchanged
  #      by reads.
  defp emit_for_reduce_single_pvec_specialized(
         iter_ast,
         target_ast,
         var,
         body_asts,
         pre_ctx,
         flow,
         context,
         acc_inlineable?,
         ro_pvec_names
       ) do
    rewritten_var = Naming.rewrite(var)
    acc_atom = String.to_atom(rewritten_var)
    acc_ref = {acc_atom, [], nil}

    # Acc-side names (nil when no write-spec).
    acc_arr_atom =
      if acc_inlineable?, do: String.to_atom("#{rewritten_var}_pvec_arr"), else: nil

    # Read-only rewrites: list of {name_atom, arr_atom} for each
    # ro pvec name. Suffix `_ro` makes the intent obvious in the
    # emitted source.
    ro_rewrites =
      Enum.map(ro_pvec_names, fn name ->
        rw = Naming.rewrite(name)
        {String.to_atom(rw), String.to_atom("#{rw}_pvec_arr_ro")}
      end)

    # Combined map for body rewriting: covers both the accumulator
    # (writes + reads) and ro pvecs (reads only).
    {acc_write_atom, body_acc_arr_atom} =
      case acc_arr_atom do
        nil -> {nil, nil}
        atom -> {acc_atom, atom}
      end

    rewritten_body =
      Enum.map(
        body_asts,
        &rewrite_for_pvec_specialized(&1, acc_write_atom, body_acc_arr_atom, ro_rewrites)
      )

    # Accumulator ref used inside the reduce closure.
    inner_acc_ref =
      case acc_arr_atom do
        nil -> acc_ref
        atom -> {atom, [], nil}
      end

    inner_body = Converter.body_to_block(rewritten_body ++ [inner_acc_ref])
    inner_body = maybe_continue_iter(inner_body, inner_acc_ref, elem(flow, 1))

    fn_ast = {:fn, [], [{:->, [], [[target_ast, inner_acc_ref], inner_body]}]}

    # Initial value: the unwrapped raw `:array` (post-unwrap binding)
    # when acc-spec fires, otherwise the existing `initial_ref` path.
    initial =
      case acc_arr_atom do
        nil -> initial_ref(var, pre_ctx)
        atom -> {atom, [], nil}
      end

    reduce =
      {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [iter_ast, initial, fn_ast]}

    rhs = maybe_break_reduce(reduce, inner_acc_ref, elem(flow, 0))

    # Pre-loop block: read-only unwraps, then acc unwrap (so the acc
    # unwrap can be the last setup step before the reduce — matches
    # the order a human would write).
    ro_unwraps =
      Enum.map(ro_rewrites, fn {name_atom, arr_atom} ->
        {:=, [], [{:py_pvec, {arr_atom, [], nil}}, {name_atom, [], nil}]}
      end)

    acc_unwrap =
      case acc_arr_atom do
        nil -> []
        atom -> [{:=, [], [{:py_pvec, {atom, [], nil}}, acc_ref]}]
      end

    # Reduce + post-loop rewrap (only if acc-spec fires).
    reduce_and_rewrap =
      case acc_arr_atom do
        nil ->
          [{:=, [], [acc_ref, rhs]}]

        atom ->
          [
            {:=, [], [{atom, [], nil}, rhs]},
            {:=, [], [acc_ref, {:py_pvec, {atom, [], nil}}]}
          ]
      end

    stmts = ro_unwraps ++ acc_unwrap ++ reduce_and_rewrap
    block = {:__block__, [], stmts}
    context = Converter.bind_name(context, var)
    {block, context}
  end

  # Eligibility check. Three conditions:
  #   1. `var` is statically typed `{:py_pvec, _}` in the surrounding
  #      context (so we know the unwrap will succeed).
  #   2. Every body statement is either a no-mention or
  #      `var = <rhs>` where rhs uses var only via the safe wrappers.
  #   3. The body has no nested function definitions / closures that
  #      could capture and leak `var` — we don't descend into those.
  defp pvec_accumulator_inlinable?(var, body_asts, context) do
    var_atom = var |> Naming.rewrite() |> String.to_atom()

    match?({:py_pvec, _}, Map.get(context.types, var)) and
      Enum.all?(body_asts, &stmt_safe_for_pvec_inline?(&1, var_atom))
  end

  # `acc = <rhs>` re-assigns the accumulator — typical mutation
  # pattern. RHS must use the name only via the safe wrappers.
  defp stmt_safe_for_pvec_inline?({:=, _, [{atom, _, nil}, rhs]}, var_atom)
       when atom == var_atom,
       do: safe_subexpr?(rhs, var_atom)

  # Any other statement must not reference `var` at all in a bare
  # context — references must be inside the safe wrappers.
  defp stmt_safe_for_pvec_inline?(stmt, var_atom),
    do: safe_subexpr?(stmt, var_atom)

  # `py_getitem(var, k)` — safe (recurse into k).
  defp safe_subexpr?({:py_getitem, _, [{atom, _, nil}, k]}, var_atom)
       when atom == var_atom,
       do: safe_subexpr?(k, var_atom)

  # `py_setitem(var, k, v)` — safe (recurse into k and v).
  defp safe_subexpr?({:py_setitem, _, [{atom, _, nil}, k, v]}, var_atom)
       when atom == var_atom,
       do: safe_subexpr?(k, var_atom) and safe_subexpr?(v, var_atom)

  # Bare `var` reference anywhere else — UNSAFE.
  defp safe_subexpr?({atom, _, nil}, var_atom) when atom == var_atom, do: false

  # Closure body (`fn ... -> ... end`) — descend; same rules apply
  # to references inside the closure.
  defp safe_subexpr?({:fn, _, clauses}, var_atom),
    do: safe_subexpr?(clauses, var_atom)

  defp safe_subexpr?(node, var_atom) when is_tuple(node) do
    node |> Tuple.to_list() |> Enum.all?(&safe_subexpr?(&1, var_atom))
  end

  defp safe_subexpr?(list, var_atom) when is_list(list) do
    Enum.all?(list, &safe_subexpr?(&1, var_atom))
  end

  defp safe_subexpr?(_, _), do: true

  # Unified body rewriter for the pvec specialization. Takes the
  # accumulator's atom + array-side atom (both nil when acc-spec is
  # not firing) and a list of `{name_atom, arr_atom}` rewrites for
  # read-only pvec names. Rewrites:
  #
  #   - `py_getitem(acc, k)` → `py_pvec_arr_get(acc_arr, k)`
  #   - `py_setitem(acc, k, v)` → `py_pvec_arr_set(acc_arr, k, v)`
  #   - LHS of `acc = …` mutations → `acc_arr = …`
  #   - `py_getitem(ro_name, k)` → `py_pvec_arr_get(ro_arr, k)`
  #     (no write rewrites for ro names — they're guarded read-only).
  defp rewrite_for_pvec_specialized(node, acc_atom, acc_arr_atom, ro_rewrites)

  defp rewrite_for_pvec_specialized(
         {:py_getitem, m, [{atom, _, nil}, k]},
         acc_atom,
         acc_arr_atom,
         ro_rewrites
       ) do
    cond do
      acc_atom != nil and atom == acc_atom ->
        {:py_pvec_arr_get, m,
         [
           {acc_arr_atom, [], nil},
           rewrite_for_pvec_specialized(k, acc_atom, acc_arr_atom, ro_rewrites)
         ]}

      arr_atom = Keyword.get(ro_rewrites, atom) ->
        {:py_pvec_arr_get, m,
         [
           {arr_atom, [], nil},
           rewrite_for_pvec_specialized(k, acc_atom, acc_arr_atom, ro_rewrites)
         ]}

      true ->
        {:py_getitem, m,
         [
           {atom, [], nil},
           rewrite_for_pvec_specialized(k, acc_atom, acc_arr_atom, ro_rewrites)
         ]}
    end
  end

  defp rewrite_for_pvec_specialized(
         {:py_setitem, m, [{atom, _, nil}, k, v]},
         acc_atom,
         acc_arr_atom,
         ro_rewrites
       )
       when acc_atom != nil and atom == acc_atom do
    {:py_pvec_arr_set, m,
     [
       {acc_arr_atom, [], nil},
       rewrite_for_pvec_specialized(k, acc_atom, acc_arr_atom, ro_rewrites),
       rewrite_for_pvec_specialized(v, acc_atom, acc_arr_atom, ro_rewrites)
     ]}
  end

  defp rewrite_for_pvec_specialized(
         {:=, m, [{atom, _, nil}, rhs]},
         acc_atom,
         acc_arr_atom,
         ro_rewrites
       )
       when acc_atom != nil and atom == acc_atom do
    {:=, m,
     [
       {acc_arr_atom, [], nil},
       rewrite_for_pvec_specialized(rhs, acc_atom, acc_arr_atom, ro_rewrites)
     ]}
  end

  defp rewrite_for_pvec_specialized(node, acc_atom, acc_arr_atom, ro_rewrites)
       when is_tuple(node) do
    node
    |> Tuple.to_list()
    |> Enum.map(&rewrite_for_pvec_specialized(&1, acc_atom, acc_arr_atom, ro_rewrites))
    |> List.to_tuple()
  end

  defp rewrite_for_pvec_specialized(list, acc_atom, acc_arr_atom, ro_rewrites)
       when is_list(list) do
    Enum.map(list, &rewrite_for_pvec_specialized(&1, acc_atom, acc_arr_atom, ro_rewrites))
  end

  defp rewrite_for_pvec_specialized(other, _, _, _), do: other

  # Find pvec-typed names referenced in the body whose use is
  # *strictly* read-only (every reference appears as the first arg
  # of `py_getitem(name, _)` — no `py_setitem`, no bare references).
  # Excludes the accumulator (handled separately by the acc-write
  # spec). Returns Python names (not atoms) so the caller can use
  # the same `Naming.rewrite` discipline as elsewhere.
  defp readonly_pvec_names_in_body(body_asts, exclude_var, context) do
    Enum.flat_map(context.types, fn {name, type} ->
      cond do
        name == exclude_var ->
          []

        match?({:py_pvec, _}, type) ->
          name_atom = name |> Naming.rewrite() |> String.to_atom()

          if name_referenced?(body_asts, name_atom) and
               body_uses_readonly?(body_asts, name_atom) do
            [name]
          else
            []
          end

        true ->
          []
      end
    end)
  end

  defp name_referenced?(node, name_atom)
  defp name_referenced?({atom, _, nil}, name_atom) when atom == name_atom, do: true

  defp name_referenced?(node, name_atom) when is_tuple(node) do
    node |> Tuple.to_list() |> Enum.any?(&name_referenced?(&1, name_atom))
  end

  defp name_referenced?(list, name_atom) when is_list(list) do
    Enum.any?(list, &name_referenced?(&1, name_atom))
  end

  defp name_referenced?(_, _), do: false

  # True when every reference to `name_atom` in `node` is inside
  # `py_getitem(name, _)` (read), and no bare references / writes
  # exist. Mirrors `safe_subexpr?/2` (the accumulator side) but
  # forbids `py_setitem` entirely.
  defp body_uses_readonly?(node, name_atom)

  defp body_uses_readonly?({:py_getitem, _, [{atom, _, nil}, k]}, name_atom)
       when atom == name_atom,
       do: body_uses_readonly?(k, name_atom)

  defp body_uses_readonly?({:py_setitem, _, [{atom, _, nil}, _, _]}, name_atom)
       when atom == name_atom,
       do: false

  defp body_uses_readonly?({atom, _, nil}, name_atom) when atom == name_atom, do: false

  defp body_uses_readonly?({:fn, _, clauses}, name_atom),
    do: body_uses_readonly?(clauses, name_atom)

  defp body_uses_readonly?(node, name_atom) when is_tuple(node) do
    node |> Tuple.to_list() |> Enum.all?(&body_uses_readonly?(&1, name_atom))
  end

  defp body_uses_readonly?(list, name_atom) when is_list(list) do
    Enum.all?(list, &body_uses_readonly?(&1, name_atom))
  end

  defp body_uses_readonly?(_, _), do: true

  defp emit_for_reduce_tuple(
         iter_ast,
         target_ast,
         vars,
         acc_refs,
         body_asts,
         pre_ctx,
         flow,
         context
       ) do
    acc_pattern = Converter.tuple_pattern(acc_refs)
    initial = Converter.tuple_pattern(Enum.map(vars, &initial_ref(&1, pre_ctx)))

    inner_body = Converter.body_to_block(body_asts ++ [acc_pattern])
    inner_body = maybe_continue_iter(inner_body, acc_pattern, elem(flow, 1))

    fn_ast = {:fn, [], [{:->, [], [[target_ast, acc_pattern], inner_body]}]}

    reduce =
      {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [iter_ast, initial, fn_ast]}

    rhs = maybe_break_reduce(reduce, acc_pattern, elem(flow, 0))
    context = Enum.reduce(vars, context, &Converter.bind_name(&2, &1))
    {{:=, [], [acc_pattern, rhs]}, context}
  end

  defp maybe_continue_iter(body_block, _acc, false), do: body_block

  defp maybe_continue_iter(body_block, acc_ast, true) do
    catch_clause = ControlFlow.catch_continue(acc_ast, acc_ast)
    {:try, [], [[do: body_block, catch: [catch_clause]]]}
  end

  defp maybe_break_reduce(reduce_call, _acc_pattern, false), do: reduce_call

  defp maybe_break_reduce(reduce_call, acc_pattern, true) do
    catch_clause = ControlFlow.catch_break(acc_pattern, acc_pattern)
    {:try, [], [[do: reduce_call, catch: [catch_clause]]]}
  end

  defp initial_ref(var, context) do
    cond do
      Converter.var_bound?(context, var) ->
        {var |> Naming.rewrite() |> String.to_atom(), [], nil}

      # Demoted top-level defs are emitted as `name = fn … end` bindings
      # at module-runtime-statements position in py_main. At conversion
      # time the binding isn't yet in `scopes` (the def appears AFTER
      # the call site in source order is common), but the closure WILL
      # be bound by the time the caller actually invokes us. Threading
      # the name through as a value is therefore safe and lets the
      # extracted top-level `defp while_N/<arity>` reach the closure.
      MapSet.member?(context.demoted_functions, var) ->
        {var |> Naming.rewrite() |> String.to_atom(), [], nil}

      true ->
        nil
    end
  end
end
