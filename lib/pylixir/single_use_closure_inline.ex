defmodule Pylixir.SingleUseClosureInline do
  @moduledoc """
  Inline closure bindings whose sole caller is a direct call site
  inside the same lexical scope.

  Two flavours:

    * **Value-position inline.** `Assign(Name=N, Lambda(args, body))`
      or `FunctionDef(name=N, args, body=[Return(expr)])` followed by
      one `Call(Name(N), CALL_ARGS)` anywhere in `rest`. Each
      `CALL_ARGS[i]` must be a `Name` AST whose `id` equals the
      corresponding param name (trivial substitution — no alpha
      rename). Replace the call with `expr` (or the lambda body),
      drop the original binding.

    * **Statement-position inline.** `FunctionDef(name=N, args=[],
      body=stmts)` followed by exactly one `Expr(Call(Name(N)))`
      somewhere in `rest`, optionally wrapped in
      `If(__name__ == "__main__")`. Replace that statement (or the
      wrapping `If`) with `stmts`, drop the original `FunctionDef`.

  Both flavours require `N` to be referenced **exactly once** in
  `rest` (any extra reference disqualifies — captures and other
  closures count). The single reference must be a direct call, not a
  `&N/k` capture, attribute access, or bare `Name(N)` read.

  Walk is post-order: each `FunctionDef.body` is rewritten first, then
  the enclosing statement list. No re-scan on the rewritten list —
  successive single-use closures only chain if they were already in
  separate scopes before the pass.

  Public entry: `rewrite/1` over a list of statements (a function
  body or the module's runtime_statements).
  """

  @spec rewrite([map()]) :: [map()]
  def rewrite(stmts) when is_list(stmts) do
    stmts
    |> Enum.map(&recurse_into/1)
    |> inline_pass()
  end

  # Recurse into nodes that own a body list (FunctionDef, the few
  # statement nodes that hold nested blocks). Lambdas have expression
  # bodies, not statement lists, so they don't need recursion at this
  # level — value-inline catches them when they appear as Assign
  # values.
  defp recurse_into(%{"_type" => "FunctionDef", "body" => body} = node) when is_list(body) do
    %{node | "body" => rewrite(body)}
  end

  defp recurse_into(%{"_type" => "AsyncFunctionDef", "body" => body} = node) when is_list(body) do
    %{node | "body" => rewrite(body)}
  end

  defp recurse_into(%{"_type" => "If", "body" => b, "orelse" => o} = node) when is_list(b) do
    %{node | "body" => rewrite(b), "orelse" => rewrite(o)}
  end

  defp recurse_into(%{"_type" => "While", "body" => b, "orelse" => o} = node) when is_list(b) do
    %{node | "body" => rewrite(b), "orelse" => rewrite(o)}
  end

  defp recurse_into(%{"_type" => "For", "body" => b, "orelse" => o} = node) when is_list(b) do
    %{node | "body" => rewrite(b), "orelse" => rewrite(o)}
  end

  defp recurse_into(%{"_type" => "Try"} = node) do
    %{
      node
      | "body" => rewrite(node["body"] || []),
        "orelse" => rewrite(node["orelse"] || []),
        "finalbody" => rewrite(node["finalbody"] || [])
    }
  end

  defp recurse_into(node), do: node

  # Scan a statement list once for inline targets. If a target fires,
  # the surrounding statement list is rebuilt with the target removed
  # and its single-use call replaced. The pass is conservative: any
  # disqualifier (multi-arg-mismatch, multi-reference, non-Call usage)
  # leaves the statement untouched.
  defp inline_pass(stmts) do
    case scan_for_target(stmts, []) do
      :no -> stmts
      {:ok, new_stmts} -> inline_pass(new_stmts)
    end
  end

  defp scan_for_target([], _acc), do: :no

  defp scan_for_target([stmt | rest], acc) do
    case inline_target(stmt) do
      {:ok, name, params, body_expr, :value} ->
        case try_value_inline(rest, name, params, body_expr) do
          {:ok, new_rest} -> {:ok, Enum.reverse(acc) ++ new_rest}
          :no -> scan_for_target(rest, [stmt | acc])
        end

      {:ok, name, [], body_stmts, :statement} ->
        case try_statement_inline(rest, name, body_stmts) do
          {:ok, new_rest} -> {:ok, Enum.reverse(acc) ++ new_rest}
          :no -> scan_for_target(rest, [stmt | acc])
        end

      :no ->
        scan_for_target(rest, [stmt | acc])
    end
  end

  # Classify a statement as an inline target.
  #
  # FunctionDef with single-`Return(expr)` body → value-inline target.
  # FunctionDef with multi-stmt body AND zero args → statement-inline.
  # Assign(Name=N, Lambda) → value-inline target.
  defp inline_target(%{
         "_type" => "FunctionDef",
         "name" => name,
         "args" => args,
         "body" => [%{"_type" => "Return", "value" => value}]
       })
       when not is_nil(value) do
    if simple_args?(args), do: {:ok, name, arg_names(args), value, :value}, else: :no
  end

  defp inline_target(%{
         "_type" => "FunctionDef",
         "name" => name,
         "args" => args,
         "body" => body
       })
       when is_list(body) and body != [] do
    if simple_args?(args) and arg_names(args) == [] and not body_has_function_exit?(body) do
      {:ok, name, [], strip_leading_docstring(body), :statement}
    else
      :no
    end
  end

  defp inline_target(%{
         "_type" => "Assign",
         "targets" => [%{"_type" => "Name", "id" => name}],
         "value" => %{"_type" => "Lambda", "args" => args, "body" => body}
       }) do
    if simple_args?(args), do: {:ok, name, arg_names(args), body, :value}, else: :no
  end

  defp inline_target(_), do: :no

  defp simple_args?(args) do
    Map.get(args, "vararg") == nil and
      Map.get(args, "kwarg") == nil and
      Map.get(args, "defaults", []) == [] and
      Map.get(args, "kw_defaults", []) == [] and
      Map.get(args, "kwonlyargs", []) == [] and
      Map.get(args, "posonlyargs", []) == []
  end

  defp arg_names(args), do: (args["args"] || []) |> Enum.map(& &1["arg"])

  # Value-position inline: count references in `rest`; require exactly
  # one, that one being a direct `Call(Name(N), CALL_ARGS)` with each
  # `CALL_ARGS[i]` matching `params[i]`.
  defp try_value_inline(rest, name, params, body_expr) do
    if name_ref_count(rest, name) == 1 do
      case rewrite_value_call(rest, name, params, body_expr, false) do
        {new_rest, true} -> {:ok, new_rest}
        _ -> :no
      end
    else
      :no
    end
  end

  # Statement-position inline: count references; require exactly one,
  # that one being either a bare `Expr(Call(Name(N)))` statement or
  # `If(__name__ == "__main__", [Expr(Call(N))], [])`.
  defp try_statement_inline(rest, name, body_stmts) do
    if name_ref_count(rest, name) == 1 do
      case rewrite_statement_call(rest, name, body_stmts, false) do
        {new_rest, true} -> {:ok, new_rest}
        _ -> :no
      end
    else
      :no
    end
  end

  # Count `Name(id=name)` references anywhere in the subtree, ignoring
  # binding positions (Assign target, FunctionDef.name, etc.). Cheap
  # over-count: even Store-context Names are tallied (shadowing
  # reassign is conservatively treated as a reference, blocking the
  # inline) — but that doesn't fire on the church-numerals patterns
  # we care about.
  defp name_ref_count(node, target), do: do_name_count(node, target, 0)

  defp do_name_count(%{"_type" => "Name", "id" => id}, target, acc),
    do: if(id == target, do: acc + 1, else: acc)

  defp do_name_count(node, target, acc) when is_map(node) do
    Enum.reduce(Map.delete(node, "_type"), acc, fn {_k, v}, a ->
      do_name_count(v, target, a)
    end)
  end

  defp do_name_count(list, target, acc) when is_list(list),
    do: Enum.reduce(list, acc, fn item, a -> do_name_count(item, target, a) end)

  defp do_name_count(_leaf, _target, acc), do: acc

  # Walk the statement list looking for the single `Call(Name(N),
  # args)` whose args match `params`. Return `{rewritten_stmts, true}`
  # when found and replaced, `{stmts, false}` otherwise.
  defp rewrite_value_call(stmts, name, params, body_expr, done?) do
    Enum.map_reduce(stmts, done?, fn stmt, done? ->
      {new, done?} = walk_value_call(stmt, name, params, body_expr, done?)
      {new, done?}
    end)
  end

  defp walk_value_call(
         %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => id}, "args" => call_args} =
           node,
         name,
         params,
         body_expr,
         false
       )
       when id == name do
    if args_match_params?(call_args, params) do
      {body_expr, true}
    else
      # Args don't match — leave the Call as is. Recurse into children
      # in case the actual single ref is nested elsewhere (rare, but
      # defensive).
      walk_value_children(node, name, params, body_expr, false)
    end
  end

  defp walk_value_call(node, name, params, body_expr, done?) when is_map(node) do
    walk_value_children(node, name, params, body_expr, done?)
  end

  defp walk_value_call(list, name, params, body_expr, done?) when is_list(list) do
    Enum.map_reduce(list, done?, fn item, d ->
      walk_value_call(item, name, params, body_expr, d)
    end)
  end

  defp walk_value_call(leaf, _name, _params, _body_expr, done?), do: {leaf, done?}

  defp walk_value_children(node, name, params, body_expr, done?) when is_map(node) do
    {pairs, done?} =
      node
      |> Map.delete("_type")
      |> Enum.map_reduce(done?, fn {k, v}, d ->
        {new_v, d} = walk_value_call(v, name, params, body_expr, d)
        {{k, new_v}, d}
      end)

    type = Map.get(node, "_type")
    rebuilt = pairs |> Map.new() |> Map.put("_type", type)
    {rebuilt, done?}
  end

  defp args_match_params?(call_args, params) when length(call_args) == length(params) do
    Enum.zip(call_args, params)
    |> Enum.all?(fn
      {%{"_type" => "Name", "id" => id}, p} -> id == p
      _ -> false
    end)
  end

  defp args_match_params?(_, _), do: false

  # Statement-position rewriter: find either `Expr(Call(Name(N)))` or
  # `If(__name__ == "__main__", [that Expr], [])`, splice body_stmts
  # in place.
  defp rewrite_statement_call(stmts, name, body_stmts, _done?) do
    {rewritten, found?} =
      Enum.flat_map_reduce(stmts, false, fn stmt, found? ->
        cond do
          not found? and bare_call_stmt?(stmt, name) ->
            {body_stmts, true}

          not found? and main_guarded_call?(stmt, name) ->
            {body_stmts, true}

          true ->
            {[stmt], found?}
        end
      end)

    {rewritten, found?}
  end

  defp bare_call_stmt?(
         %{
           "_type" => "Expr",
           "value" => %{
             "_type" => "Call",
             "func" => %{"_type" => "Name", "id" => id},
             "args" => []
           }
         },
         name
       ),
       do: id == name

  defp bare_call_stmt?(_, _), do: false

  defp main_guarded_call?(
         %{"_type" => "If", "test" => test, "body" => [inner], "orelse" => []},
         name
       ),
       do: name_eq_main_test?(test) and bare_call_stmt?(inner, name)

  defp main_guarded_call?(_, _), do: false

  defp name_eq_main_test?(%{
         "_type" => "Compare",
         "left" => %{"_type" => "Name", "id" => "__name__"},
         "ops" => [%{"_type" => "Eq"}],
         "comparators" => [%{"_type" => "Constant", "value" => "__main__"}]
       }),
       do: true

  defp name_eq_main_test?(_), do: false

  # Statement-position inline splices a `def f(): body` body into the
  # call site. If `body` carries a `Return` (or `Yield` — making it a
  # generator), the spliced node loses its enclosing function: a
  # module-scope `Return` is a Python SyntaxError, and `Yield` only
  # makes sense inside a generator. Walk `body` looking for those at
  # *this* function's level — descend through control-flow (If/For/
  # While/Try/With) but stop at nested defs/lambdas/classes, whose
  # Returns belong to their own enclosing function.
  defp body_has_function_exit?(node) when is_map(node) do
    case Map.get(node, "_type") do
      "Return" -> true
      "Yield" -> true
      "YieldFrom" -> true
      "FunctionDef" -> false
      "AsyncFunctionDef" -> false
      "Lambda" -> false
      "ClassDef" -> false
      _ -> node |> Map.delete("_type") |> Enum.any?(fn {_k, v} -> body_has_function_exit?(v) end)
    end
  end

  defp body_has_function_exit?(list) when is_list(list),
    do: Enum.any?(list, &body_has_function_exit?/1)

  defp body_has_function_exit?(_), do: false

  # PEP 257: a function body's first statement that is a string
  # Constant is the docstring. Mirror `Pylixir.Nodes.Functions`'
  # `strip_docstring/1` so spliced bodies don't leave a stray bare
  # string literal at the inline site.
  defp strip_leading_docstring([
         %{"_type" => "Expr", "value" => %{"_type" => "Constant", "value" => v}} | rest
       ])
       when is_binary(v),
       do: rest

  defp strip_leading_docstring(body), do: body
end
