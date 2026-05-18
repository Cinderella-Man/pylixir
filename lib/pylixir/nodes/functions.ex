defmodule Pylixir.Nodes.Functions do
  @moduledoc """
  Lower function-emitting Python nodes: `FunctionDef` (top-level), nested
  `FunctionDef` (one level inside another `def`), and `Lambda`.

  The three share the parameter / argument plumbing
  (`validate_arguments!`, `reject_defaults!`, `build_param_asts`,
  `arg_names`) and the early-`return` machinery
  (`decide_return_mode` + `maybe_wrap_return_catch`).

  ## Return-wrap decision

  A function body with a single tail-position `Return` stays
  `:unwrapped` (the last expression's value is the return). Any other
  shape (multiple returns, or one early return) is `:wrapped`: every
  `Return` throws `{:pylixir_return, value}`, and the body is wrapped
  in `try/catch`. This keeps the common case clean and pushes the
  throw overhead only into bodies that need it (see CONTEXT.md's
  "Helper" entry and `Pylixir.Context.return_mode`).

  ## Recursive nested fns

  A nested `def foo(...)` that calls itself can't reference itself
  through the bound name (would crash at runtime — the lambda doesn't
  see its own name during construction). We pass `self` as an extra
  parameter; the call site picks it up via `Context.recursive_lambdas`.

  Cross-section helpers (`convert`, `convert_each`, `bind_name`,
  `body_to_block`) live on `Pylixir.Converter`.
  """

  alias Pylixir.{AST.Walk, Context, ControlFlow, Converter, Naming, UnsupportedNodeError}

  # --- Public entry points -----------------------------------------------

  @spec function_def(map(), Context.t()) :: {Macro.t(), Context.t()}
  def function_def(node, context) do
    case context.def_position do
      :module_top ->
        emit_function_def(node, context)

      :nested_fn ->
        emit_nested_function_def(node, context)

      :other ->
        raise UnsupportedNodeError,
          node_type: "FunctionDef",
          hint:
            "function definitions inside control flow are not supported; lift to module level",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  @spec lambda(map(), Context.t()) :: {Macro.t(), Context.t()}
  def lambda(%{"args" => args, "body" => body} = node, context) do
    validate_arguments!(args, node)
    reject_defaults!(args, "Lambda", node)
    {param_asts, context} = build_param_asts(args, context)
    param_names = arg_names(args)

    saved_scopes = context.scopes
    new_scope = MapSet.new(param_names)
    context = %{context | scopes: [new_scope | context.scopes]}

    {body_ast, context} = Converter.convert(body, context)

    context = %{context | scopes: saved_scopes}

    {{:fn, [], [{:->, [], [param_asts, body_ast]}]}, context}
  end

  # --- Nested FunctionDef (T21) ------------------------------------------

  defp emit_nested_function_def(node, context) do
    %{"name" => name, "args" => args, "body" => body} = node

    case Map.get(node, "decorator_list", []) |> Enum.reject(&safe_to_strip_decorator?/1) do
      [] ->
        :ok

      [_unsupported | _] ->
        raise UnsupportedNodeError,
          node_type: "FunctionDef",
          hint: "decorators on nested functions are not supported",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end

    validate_arguments!(args, node)
    reject_defaults!(args, "nested FunctionDef", node)

    recursive? = self_referential?(body, name)

    {param_asts, context} = build_param_asts(args, context)
    param_names = arg_names(args)
    return_mode = decide_return_mode(body)

    saved_scopes = context.scopes
    saved_self = context.recursive_self_binding
    saved_return_mode = context.return_mode

    inner_scope_names =
      if recursive?, do: param_names ++ ["self"], else: param_names

    context = %{
      context
      | scopes: [MapSet.new(inner_scope_names) | context.scopes],
        recursive_self_binding: if(recursive?, do: name, else: saved_self),
        return_mode: return_mode
    }

    {body_asts, context} = Converter.convert_each(strip_docstring(body), context)

    context = %{
      context
      | scopes: saved_scopes,
        recursive_self_binding: saved_self,
        return_mode: saved_return_mode
    }

    body_block =
      case body_asts do
        [] -> nil
        _ -> Converter.body_to_block(body_asts)
      end

    body_block = maybe_wrap_return_catch(body_block, return_mode)

    fn_params = if recursive?, do: param_asts ++ [{:self, [], nil}], else: param_asts
    fn_ast = {:fn, [], [{:->, [], [fn_params, body_block]}]}

    name_atom = name |> Naming.rewrite() |> String.to_atom()

    context = Converter.bind_name(context, name)

    context =
      if recursive? do
        %{context | recursive_lambdas: MapSet.put(context.recursive_lambdas, name)}
      else
        context
      end

    {{:=, [], [{name_atom, [], nil}, fn_ast]}, context}
  end

  # --- Top-level FunctionDef (T19) ---------------------------------------

  defp emit_function_def(node, context) do
    %{"name" => py_name, "args" => args, "body" => body} = node

    case Map.get(node, "decorator_list", []) |> Enum.reject(&safe_to_strip_decorator?/1) do
      [] ->
        :ok

      [_unsupported | _] ->
        raise UnsupportedNodeError,
          node_type: "FunctionDef",
          hint: "Python decorators are not supported",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end

    validate_arguments!(args, node)

    {param_asts, context} = build_param_asts(args, context)
    param_names = arg_names(args)

    return_mode = decide_return_mode(body)

    saved_scopes = context.scopes
    saved_def_position = context.def_position
    saved_return_mode = context.return_mode
    saved_types = context.types

    new_scope = MapSet.new(param_names)

    # PR 9 — prime param types from `fn_signatures` so the body's
    # converter clauses see typed params. Falls back to `:any` when no
    # signature was inferred (variadic / first-pass / etc.).
    param_types =
      case Map.get(context.fn_signatures, py_name) do
        {pts, _} when is_list(pts) and length(pts) == length(param_names) -> pts
        _ -> List.duplicate(:any, length(param_names))
      end

    primed_types =
      param_names
      |> Enum.zip(param_types)
      |> Enum.reduce(context.types, fn {name, t}, acc -> Map.put(acc, name, t) end)

    context = %{
      context
      | scopes: [new_scope | context.scopes],
        def_position: :nested_fn,
        return_mode: return_mode,
        types: primed_types
    }

    {doc, stripped_body} = extract_docstring(body)
    {body_asts, context} = Converter.convert_each(stripped_body, context)

    context = %{
      context
      | scopes: saved_scopes,
        def_position: saved_def_position,
        return_mode: saved_return_mode,
        types: saved_types
    }

    body_block =
      case body_asts do
        [] -> nil
        _ -> Converter.body_to_block(body_asts)
      end

    body_block = maybe_wrap_return_catch(body_block, return_mode)

    fn_name_atom = py_name |> Naming.rewrite() |> String.to_atom()
    # Top-level Python `def f` → Elixir `def f` (not `defp`). Two
    # reasons: `@doc` only attaches cleanly to public functions (defp
    # warns "always discarded"), and `apply(__MODULE__, :f, args)`
    # in the star-unpack-call path needs `f` to be reachable.
    def_ast = {:def, [], [{fn_name_atom, [], param_asts}, [do: body_block]]}

    case doc do
      nil ->
        {def_ast, context}

      text when is_binary(text) ->
        doc_attr = {:@, [], [{:doc, [], [text]}]}
        {{:__block__, [], [doc_attr, def_ast]}, context}
    end
  end

  # --- Return-mode + parameter plumbing (shared) -------------------------

  # Decorators we can safely strip because dropping them only loses
  # performance, not correctness. `lru_cache`/`cache` add memoization
  # — Pylixir would need a Process-backed memo table to mirror this,
  # but plain re-computation still produces the right answer.
  defp safe_to_strip_decorator?(%{"_type" => "Name", "id" => id})
       when id in ~w(cache lru_cache),
       do: true

  defp safe_to_strip_decorator?(%{"_type" => "Call", "func" => func}),
    do: safe_to_strip_decorator?(func)

  defp safe_to_strip_decorator?(%{
         "_type" => "Attribute",
         "value" => %{"_type" => "Name", "id" => "functools"},
         "attr" => attr
       })
       when attr in ~w(cache lru_cache),
       do: true

  defp safe_to_strip_decorator?(_), do: false

  # Python's convention (PEP 257): a function body's first statement
  # that is just a string Constant is the docstring. Elixir warns
  # about unused literals, so drop the leading docstring before
  # lowering. For top-level `def`s the Converter promotes it to
  # `@doc` (via `extract_docstring/1`); for closures/lambdas there's
  # no equivalent and we just strip.
  defp strip_docstring([%{"_type" => "Expr", "value" => %{"_type" => "Constant", "value" => v}} | rest])
       when is_binary(v),
       do: rest

  defp strip_docstring(body), do: body

  # Same shape as strip_docstring/1 but returns the docstring text so
  # `emit_function_def` can attach it as `@doc` before the emitted
  # `def`. `{nil, body}` when the body has no leading docstring.
  defp extract_docstring([
         %{"_type" => "Expr", "value" => %{"_type" => "Constant", "value" => v}} | rest
       ])
       when is_binary(v),
       do: {v, rest}

  defp extract_docstring(body), do: {nil, body}

  defp self_referential?(body, name) do
    Enum.any?(body, fn stmt ->
      Walk.walk_scope(stmt, false, fn
        %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => id}}, _ when id == name ->
          true

        _, acc ->
          acc
      end)
    end)
  end

  # Conservative wrap rule: wrap iff 2+ Returns, OR exactly 1 Return
  # that is NOT the function body's literal final top-level statement.
  defp decide_return_mode(body) do
    returns = collect_returns(body)

    cond do
      returns == [] -> :unwrapped
      length(returns) == 1 and last_is_return?(body) -> :unwrapped
      true -> :wrapped
    end
  end

  defp collect_returns(body) do
    Enum.reduce(body, [], fn stmt, acc ->
      Walk.walk_scope(stmt, acc, fn
        %{"_type" => "Return"} = ret, list -> [ret | list]
        _, list -> list
      end)
    end)
  end

  defp last_is_return?([]), do: false
  defp last_is_return?(body), do: match?(%{"_type" => "Return"}, List.last(body))

  defp maybe_wrap_return_catch(body_block, :unwrapped), do: body_block
  defp maybe_wrap_return_catch(nil, :wrapped), do: nil

  defp maybe_wrap_return_catch(body_block, :wrapped) do
    val_ref = {:val, [], nil}
    catch_clause = ControlFlow.catch_return(val_ref, val_ref)
    {:try, [], [[do: body_block, catch: [catch_clause]]]}
  end

  defp validate_arguments!(args, node) do
    cond do
      Map.get(args, "vararg") != nil ->
        raise UnsupportedNodeError,
          node_type: "FunctionDef",
          hint: "Python `*args` (varargs) parameter is not supported",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      Map.get(args, "kwarg") != nil ->
        raise UnsupportedNodeError,
          node_type: "FunctionDef",
          hint: "Python `**kwargs` parameter is not supported",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      Map.get(args, "kwonlyargs", []) != [] ->
        raise UnsupportedNodeError,
          node_type: "FunctionDef",
          hint: "Python keyword-only parameters (`*, x`) are not supported",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      Map.get(args, "posonlyargs", []) != [] ->
        raise UnsupportedNodeError,
          node_type: "FunctionDef",
          hint: "Python positional-only parameters (`x, /`) are not supported",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      true ->
        :ok
    end
  end

  defp arg_names(args) do
    args |> Map.get("args", []) |> Enum.map(& &1["arg"])
  end

  defp reject_defaults!(args, kind, node) do
    if Map.get(args, "defaults", []) != [] do
      raise UnsupportedNodeError,
        node_type: "FunctionDef",
        hint:
          "default arguments on a #{kind} are not supported — Elixir `fn` does not accept defaults",
        lineno: Map.get(node, "lineno"),
        col_offset: Map.get(node, "col_offset")
    end
  end

  defp build_param_asts(args, context) do
    arg_list = Map.get(args, "args", [])
    defaults = Map.get(args, "defaults", [])
    defaults_start = length(arg_list) - length(defaults)

    {asts, context} =
      arg_list
      |> Enum.with_index()
      |> Enum.reduce({[], context}, fn {arg, i}, {acc, ctx} ->
        arg_atom = arg["arg"] |> Naming.rewrite() |> String.to_atom()
        arg_ref = {arg_atom, [], nil}

        if i >= defaults_start do
          default_node = Enum.at(defaults, i - defaults_start)
          {default_ast, ctx} = Converter.convert(default_node, ctx)
          {[{:\\, [], [arg_ref, default_ast]} | acc], ctx}
        else
          {[arg_ref | acc], ctx}
        end
      end)

    {Enum.reverse(asts), context}
  end
end
