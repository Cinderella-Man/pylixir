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
    if Map.get(node, "orelse", []) != [] do
      raise UnsupportedNodeError,
        node_type: "While",
        hint: "while/else (Python's while-loop `else` clause) is not supported",
        lineno: Map.get(node, "lineno"),
        col_offset: Map.get(node, "col_offset")
    end

    emit_while(%{"test" => test, "body" => body}, context)
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

    read_only =
      analysis.referenced_vars
      |> MapSet.union(referenced_in_test)
      |> MapSet.difference(threaded_set)
      |> MapSet.to_list()
      |> Enum.filter(&Converter.var_bound?(pre_loop_context, &1))
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

    {iter_ast, context} = Converter.convert(iter, context)
    {target_ast, target_names, context} = Converter.convert_loop_target(target, context)

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

    # Restore scopes; re-bind threaded vars for the post-loop env.
    context = %{context | scopes: saved_scopes}
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

    {iter_ast, context} = Converter.convert(iter, context)

    # Save scopes BEFORE convert_loop_target (which binds the target)
    # so we can drop the target binding after the loop. Pylixir's
    # for-loop emission uses `Enum.each`/`Enum.reduce` with the target
    # as a callback parameter — the target isn't visible after the
    # callback, so the context-level binding mustn't outlive the loop
    # either. Body-assigned threaded vars get re-bound below.
    saved_scopes = context.scopes
    {target_ast, target_names, context} = Converter.convert_loop_target(target, context)

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

    {result_ast, context} =
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

    # Restore scopes — drops target binding AND any body-locals — then
    # re-bind only the threaded vars (those that the emitter explicitly
    # threads through the accumulator and are visible post-loop).
    context = %{context | scopes: saved_scopes}
    context = Enum.reduce(threaded, context, fn v, ctx -> Converter.bind_name(ctx, v) end)

    {result_ast, context}
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

    if type in ~w(FunctionDef AsyncFunctionDef Lambda ClassDef For AsyncFor While
                  ListComp SetComp DictComp GeneratorExp) do
      acc
    else
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
    if Converter.var_bound?(context, var) do
      {var |> Naming.rewrite() |> String.to_atom(), [], nil}
    else
      nil
    end
  end
end
