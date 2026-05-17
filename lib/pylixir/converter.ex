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

  alias Pylixir.AST.{BoolReturning, Trivial}

  alias Pylixir.{
    Builtins,
    Context,
    ControlFlow,
    HelpersCodegen,
    Lowering,
    ModuleAnalysis,
    Naming,
    Nodes,
    Stdlib,
    UnsupportedNodeError
  }

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

    # Runtime statements live inside py_main. FunctionDefs that appear
    # here are either (a) top-level defs demoted by ModuleAnalysis
    # because they close over mutable module state, or (b) Python defs
    # inside control flow (`if cond: def foo()`). Both are correctly
    # emitted as `name = fn ... end` lambda bindings via the
    # `:nested_fn` path — that closes over the surrounding py_main
    # scope, which is what Python's `def` semantics require here.
    context = %{context | def_position: :nested_fn}
    {stmt_asts, context} = convert_each(analysis.runtime_statements, context)
    context = %{context | def_position: :module_top}

    helpers = HelpersCodegen.helpers_ast()

    moduledoc = moduledoc_ast(analysis.module_doc)

    body_block =
      moduledoc ++
        helpers ++ attr_asts ++ fn_asts ++ context.while_helpers ++ [py_main_def(stmt_asts)]

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

  def convert(%{"_type" => "Pass"}, context), do: {:ok, context}

  # `raise ExceptionClass(args)` / `raise ExceptionClass` / bare
  # `raise` — Python's exception-raising. Pylixir doesn't model
  # exception classes, so we route everything through
  # `RuntimeError` and stringify the message: `raise X("msg")` lowers
  # to `raise(RuntimeError, "X: msg")`. Bare `re-raise` (`raise` with
  # no exc inside an except) is rejected — it needs the original
  # exception's binding which we don't track.
  def convert(%{"_type" => "Raise", "exc" => exc}, context) do
    case exc do
      nil ->
        raise UnsupportedNodeError,
          node_type: "Raise",
          hint: "bare `raise` (re-raise) is not supported — name the exception explicitly"

      %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => cls}, "args" => args} ->
        emit_raise(cls, args, context)

      %{"_type" => "Name", "id" => cls} ->
        emit_raise(cls, [], context)

      other ->
        raise UnsupportedNodeError,
          node_type: "Raise",
          hint:
            "raise target must be `ClassName(...)` or `ClassName`; got `#{Map.get(other, "_type")}`"
    end
  end

  # Walrus operator (PEP 572): `(n := expr)` is both an assignment
  # AND an expression that yields the assigned value. Elixir's `=`
  # already has both shapes — `(n = 5) > 0` works directly. The Name
  # target binds in the surrounding scope (Pylixir treats it like an
  # Assign — `bind_name` records it).
  def convert(%{"_type" => "NamedExpr", "target" => target, "value" => value}, context) do
    case target do
      %{"_type" => "Name", "id" => id} ->
        {value_ast, context} = convert(value, context)
        context = bind_name(context, id)
        target_atom = id |> Naming.rewrite() |> String.to_atom()
        {{:=, [], [{target_atom, [], nil}, value_ast]}, context}

      other ->
        raise UnsupportedNodeError,
          node_type: "NamedExpr",
          hint:
            "walrus target must be a bare Name (`(n := expr)`); got `#{Map.get(other, "_type")}`"
    end
  end

  # `del coll[k]` — rebind `coll` via `py_delitem` (polymorphic on
  # list/map/MapSet). Multi-target `del a, b` becomes a block. Other
  # target shapes (bare Name `del x`, Attribute, Tuple) still raise.
  def convert(%{"_type" => "Delete", "targets" => targets} = node, context) do
    {asts, context} =
      Enum.reduce(targets, {[], context}, fn target, {acc, ctx} ->
        {ast, ctx} = convert_del_target(target, node, ctx)
        {[ast | acc], ctx}
      end)

    body =
      case Enum.reverse(asts) do
        [single] -> single
        many -> {:__block__, [], many}
      end

    {body, context}
  end

  def convert(%{"_type" => "Assert", "test" => test} = node, context) do
    {test_ast, context} = convert_test(test, context)

    msg_ast =
      case Map.get(node, "msg") do
        nil ->
          "AssertionError"

        msg ->
          {ast, _} = convert(msg, context)
          ast
      end

    raise_call =
      {:raise, [], [{{:., [], [{:__aliases__, [], [:RuntimeError]}, :exception]}, [], [msg_ast]}]}

    {{:unless, [], [test_ast, [do: raise_call]]}, context}
  end

  # Imports are no-ops in generated Elixir — `Pylixir.Stdlib` modules
  # supply their own translations at attribute / call sites. Reject any
  # module name the registry doesn't know about. `functools` is
  # accepted as a no-op so the user's `@functools.lru_cache` decorator
  # path resolves (the decorator itself is stripped at the def site).
  @import_no_ops ~w(functools)

  def convert(%{"_type" => "Import", "names" => names}, context) do
    case Enum.find(names, fn %{"name" => n} ->
           not Stdlib.supported?(n) and n not in @import_no_ops
         end) do
      nil ->
        {{:__block__, [], []}, context}

      %{"name" => unknown} ->
        raise UnsupportedNodeError,
          node_type: "Import",
          hint:
            "no stdlib translation for `import #{unknown}` (known: #{Enum.join(Stdlib.names(), ", ")})"
    end
  end

  def convert(%{"_type" => "ImportFrom", "module" => "__future__"}, context),
    do: {{:__block__, [], []}, context}

  # `from functools import lru_cache, cache` — both are decorator
  # no-ops (we don't memoize; functions just re-compute). functools
  # isn't a Stdlib registry member (no `call/4` lowerings), so it has
  # its own no-op clause rather than going through `import_binding/1`.
  def convert(%{"_type" => "ImportFrom", "module" => "functools", "names" => names}, context) do
    allowed = ~w(lru_cache cache reduce)

    unknown = Enum.find(names, fn %{"name" => n} -> n not in allowed end)

    if unknown do
      raise UnsupportedNodeError,
        node_type: "ImportFrom",
        hint:
          "`from functools import #{unknown["name"]}` is not supported (allowed: #{Enum.join(allowed, ", ")})"
    end

    {{:__block__, [], []}, context}
  end

  # `from <stdlib_mod> import <names>` — delegates the per-name RHS
  # shape to `<Stdlib.Module>.import_binding/1`. Stdlib modules own
  # whether each name is a value-binding, a `&capture/N`, or a
  # sentinel-`nil` for downstream alias-rewrite. Adding a stdlib that
  # supports from-import is one file edit, not a Converter change.
  def convert(%{"_type" => "ImportFrom", "module" => mod, "names" => names} = node, context) do
    case Stdlib.impl(mod) do
      nil ->
        raise UnsupportedNodeError,
          node_type: "ImportFrom",
          hint:
            "`from #{mod} import ...` is not supported (only `from __future__`; for stdlib modules use `import #{mod}` and reference via `#{mod}.<name>`)",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      impl ->
        {stmts, context} =
          Enum.reduce(names, {[], context}, fn entry, {acc, ctx} ->
            n = entry["name"]
            alias = entry["asname"] || n
            {stmt, ctx} = stdlib_from_import_alias(mod, impl, n, alias, ctx, node)
            {[stmt | acc], ctx}
          end)

        body =
          case Enum.reverse(stmts) do
            [] -> {:__block__, [], []}
            [single] -> single
            many -> {:__block__, [], many}
          end

        {body, context}
    end
  end

  # Minimal Call clause — supports `Name(args)` calls only. T28 will
  # generalize to `Attribute` calls, builtins, math, kwargs, local-scope
  # shadowing precedence with explicit `.(args)` for shadowed names.
  def convert(%{"_type" => "Call"} = node, context) do
    case node["func"] do
      %{"_type" => "Name", "id" => id} ->
        emit_name_call(id, node, context)

      %{"_type" => "Attribute", "value" => target, "attr" => attr} ->
        emit_attribute_call(target, attr, node, context)

      # Chained-call shape: `f(x)(y)`, `make()(arg)`, `(lambda x: x+1)(5)`.
      # The func is itself a Call/Lambda/Subscript that returns a callable.
      # Emit `(callable_ast).(args)` — Elixir's anonymous-call invocation.
      # No-kwargs only (consistent with the in-scope lambda call path).
      %{"_type" => type} when type in ["Call", "Lambda", "Subscript", "IfExp"] ->
        emit_dynamic_call(node, context)

      _ ->
        raise UnsupportedNodeError,
          node_type: "Call",
          hint:
            "unsupported call-target shape `#{Map.get(node["func"], "_type")}`; expected `Name` or `Attribute`",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  # Bare `Attribute` access (no Call). Walk the chain — if it roots at a
  # known stdlib module, dispatch to its `attribute/2` callback; otherwise
  # the access shape isn't supported (Pylixir has no general
  # object-attribute semantics).
  def convert(%{"_type" => "Attribute"} = node, context) do
    case stdlib_chain(node) do
      {:ok, mod_name, path} ->
        impl = Stdlib.impl(mod_name)

        Lowering.dispatch(
          impl.attribute(path, node),
          "`#{mod_name}.#{Enum.join(path, ".")}` is not a supported stdlib attribute",
          node,
          context
        )

      :no_stdlib ->
        attr = Map.fetch!(node, "attr")

        case detect_type_name_access(node) do
          {:ok, value_node} ->
            # `type(x).__name__` — the only "attribute on a runtime value"
            # shape we support. Lowers to `py_type_name(x)` which returns
            # Python's class name as a string ("int", "list", ...).
            {value_ast, context} = convert(value_node, context)
            {{:py_type_name, [], [value_ast]}, context}

          :no ->
            target_type = Map.get(node["value"], "_type")

            raise UnsupportedNodeError,
              node_type: "Attribute",
              hint:
                "attribute access on a non-stdlib value (`<#{target_type}>.#{attr}`) is not supported (known stdlib modules: #{Enum.join(Stdlib.names(), ", ")})",
              lineno: Map.get(node, "lineno"),
              col_offset: Map.get(node, "col_offset")
        end
    end
  end


  def convert(%{"_type" => "Return"} = node, context) do
    case context.return_mode do
      nil ->
        raise UnsupportedNodeError,
          node_type: "Return",
          hint: "`return` outside a function is a Python SyntaxError",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      :unwrapped ->
        case Map.get(node, "value") do
          nil -> {nil, context}
          value -> convert(value, context)
        end

      :wrapped ->
        {value_ast, context} =
          case Map.get(node, "value") do
            nil -> {nil, context}
            value -> convert(value, context)
          end

        {ControlFlow.throw_return(value_ast), context}
    end
  end

  def convert(%{"_type" => "FunctionDef"} = node, context),
    do: Nodes.Functions.function_def(node, context)

  def convert(%{"_type" => "ListComp", "elt" => elt, "generators" => generators}, context) do
    Nodes.Comprehension.emit(:list, elt, generators, context)
  end

  def convert(%{"_type" => "SetComp", "elt" => elt, "generators" => generators}, context) do
    Nodes.Comprehension.emit(:set, elt, generators, context)
  end

  def convert(%{"_type" => "GeneratorExp", "elt" => elt, "generators" => generators}, context) do
    Nodes.Comprehension.emit(:gen, elt, generators, context)
  end

  def convert(
        %{"_type" => "DictComp", "key" => key, "value" => value, "generators" => generators},
        context
      ) do
    Nodes.Comprehension.emit(:dict, {key, value}, generators, context)
  end

  def convert(%{"_type" => "Subscript", "value" => value, "slice" => slice}, context) do
    case slice do
      %{"_type" => "Slice"} = slice_node ->
        {value_ast, context} = convert(value, context)
        {start_ast, context} = convert_optional(Map.get(slice_node, "lower"), context)
        {stop_ast, context} = convert_optional(Map.get(slice_node, "upper"), context)
        {step_ast, context} = convert_optional(Map.get(slice_node, "step"), context)
        {{:py_slice, [], [value_ast, start_ast, stop_ast, step_ast]}, context}

      _ ->
        {value_ast, context} = convert(value, context)
        {slice_ast, context} = convert(slice, context)
        {{:py_getitem, [], [value_ast, slice_ast]}, context}
    end
  end

  def convert(%{"_type" => "Lambda"} = node, context),
    do: Nodes.Functions.lambda(node, context)

  def convert(%{"_type" => "While"} = node, context),
    do: Nodes.Loop.while_(node, context)

  def convert(%{"_type" => "For"} = node, context),
    do: Nodes.Loop.for_(node, context)

  def convert(%{"_type" => "Break"} = node, context),
    do: Nodes.Loop.break_(node, context)

  def convert(%{"_type" => "Continue"} = node, context),
    do: Nodes.Loop.continue_(node, context)

  # `try: body except [Type] [as e]: handler` — minimal lowering that
  # ignores the exception type / `as`-binding and rescues any raise.
  # `else` runs only when body completes without raising; `finally`
  # always runs (and runs even after a re-raise from the rescue path).
  # This is good enough for the common "catch ValueError / KeyError /
  # IndexError to fall back to a default" patterns in competitive code.
  def convert(%{"_type" => "Try"} = node, context) do
    %{"body" => body, "handlers" => handlers} = node
    orelse = Map.get(node, "orelse", [])
    finalbody = Map.get(node, "finalbody", [])

    {body_asts, context} = convert_each(body, context)
    body_block = body_to_block(body_asts)

    {body_block, context} =
      case orelse do
        [] ->
          {body_block, context}

        _ ->
          {else_asts, context} = convert_each(orelse, context)
          else_block = body_to_block(else_asts)
          {body_to_block([body_block, else_block]), context}
      end

    {rescue_clauses, context} =
      Enum.map_reduce(handlers, context, fn handler, ctx ->
        {handler_asts, ctx} = convert_each(handler["body"] || [], ctx)
        handler_block = body_to_block(handler_asts)
        # Catch-any pattern; ignore the type (Pylixir doesn't track
        # exception classes) and the optional `as e` binding (the
        # user's `e` would shadow our pinned `_`).
        {{:->, [], [[{:_, [], nil}], handler_block]}, ctx}
      end)

    {try_args, context} =
      case {rescue_clauses, finalbody} do
        {[], []} ->
          {[do: body_block], context}

        {_, []} ->
          {[do: body_block, rescue: rescue_clauses], context}

        {[], _} ->
          {after_asts, context} = convert_each(finalbody, context)
          after_block = body_to_block(after_asts)
          {[do: body_block, after: after_block], context}

        {_, _} ->
          {after_asts, context} = convert_each(finalbody, context)
          after_block = body_to_block(after_asts)
          {[do: body_block, rescue: rescue_clauses, after: after_block], context}
      end

    {{:try, [], [try_args]}, context}
  end

  # Expr: drop the result unless the inner value is a recognised
  # mutation method, in which case T30 rewrites it to a target
  # reassignment. Also handles the heapq statement idiom
  # `heapq.heappush(heap, item)` / `heapq.heapify(heap)` — both
  # mutate `heap` in Python and need a rebind in Pylixir.
  def convert(%{"_type" => "Expr", "value" => value}, context) do
    case Pylixir.Stdlib.Heapq.statement_mutation_call(value, context) do
      {:ok, heap_name, fn_name, args} ->
        emit_heapq_statement_rebind(heap_name, fn_name, args, context)

      :none ->
        case Nodes.Mutations.detect(value) do
          :none ->
            convert(value, context)

          {:name, target_name, method, args, kwargs, source_node} ->
            Nodes.Mutations.emit(target_name, method, args, kwargs, source_node, context)

          {:subscript, coll_name, slice, method, args, kwargs, source_node} ->
            Nodes.Mutations.emit_subscript(
              coll_name,
              slice,
              method,
              args,
              kwargs,
              source_node,
              context
            )
        end
    end
  end

  def convert(%{"_type" => "If", "test" => test, "body" => body, "orelse" => orelse}, context) do
    case orelse do
      [] -> Nodes.If.emit_only(test, body, context)
      [%{"_type" => "If"} = _elif | _] -> Nodes.If.emit_cond_chain(test, body, orelse, context)
      _ -> Nodes.If.emit_else(test, body, orelse, context)
    end
  end

  def convert(%{"_type" => "IfExp", "test" => test, "body" => body, "orelse" => orelse}, context) do
    {test_ast, context} = convert_test(test, context)
    {body_ast, context} = convert(body, context)
    {orelse_ast, context} = convert(orelse, context)
    {{:if, [], [test_ast, [do: body_ast, else: orelse_ast]]}, context}
  end

  def convert(%{"_type" => "Assign"} = node, context),
    do: Nodes.Assign.assign(node, context)

  def convert(
        %{"_type" => "AugAssign", "target" => target, "op" => op, "value" => value} = node,
        context
      ) do
    aug_assign(target, op, value, node, context)
  end

  def convert(%{"_type" => "BoolOp", "op" => op, "values" => values} = node, context) do
    op_atom = bool_op_atom(op, node)
    {asts, context} = convert_each(values, context)
    [first | rest] = asts
    fold = Enum.reduce(rest, first, fn ast, acc -> {op_atom, [], [acc, ast]} end)
    {fold, context}
  end

  def convert(
        %{"_type" => "Compare", "left" => left, "ops" => ops, "comparators" => comparators},
        context
      ) do
    Nodes.Compare.emit(left, ops, comparators, context)
  end

  def convert(%{"_type" => "List", "elts" => elts}, context) do
    reject_starred!(elts, "List")
    {asts, context} = convert_each(elts, context)
    {asts, context}
  end

  # Python's `{1, 2, 3}` set literal — lowered to `MapSet.new([…])`.
  # The empty-set case `{}` is a *Dict* in Python AST, not a Set, so
  # this clause always has at least one element.
  def convert(%{"_type" => "Set", "elts" => elts}, context) do
    reject_starred!(elts, "Set")
    {asts, context} = convert_each(elts, context)
    {{{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], [asts]}, context}
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

  def convert(%{"_type" => "Dict", "keys" => keys, "values" => values}, context) do
    # `keys` may include `nil` entries — those mark dict-unpack
    # positions (`{**other_d, "k": v}`); the corresponding `values`
    # entry is the dict to spread. Lower the whole expression to a
    # chain of `Map.merge` (or a single literal map when no unpack).
    if Enum.any?(keys, &is_nil/1) do
      emit_dict_with_unpack(keys, values, context)
    else
      {key_asts, context} = convert_each(keys, context)
      {value_asts, context} = convert_each(values, context)
      pairs = Enum.zip(key_asts, value_asts)
      {{:%{}, [], pairs}, context}
    end
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

      # A local binding (lambda/comp/for-target/Assign) shadows a
      # module attribute. Check `name_in_scope?` BEFORE module_attrs:
      # `x = 99; any(x > 3 for x in xs)` would otherwise resolve the
      # comp's `x` reference to `@var_x` (== 99), giving the wrong
      # answer for every element.
      name_in_scope?(context, id) ->
        atom = id |> Naming.rewrite() |> String.to_atom()
        {{atom, [], nil}, context}

      MapSet.member?(context.module_attrs, id) ->
        attr_name = String.to_atom("var_" <> id)
        {{:@, [], [{attr_name, [], nil}]}, context}

      Builtins.unary_capturable?(id) ->
        {Builtins.unary_capture(id), context}

      true ->
        atom = id |> Naming.rewrite() |> String.to_atom()
        {{atom, [], nil}, context}
    end
  end

  def convert(%{"_type" => "JoinedStr"} = node, context),
    do: Nodes.FString.joined_str(node, context)

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

  # --- heapq statement-mutation rebind emitter ---------------------------
  #
  # Recognition lives on `Pylixir.Stdlib.Heapq.statement_mutation_call/2`
  # (used by Converter / ModuleAnalysis / LoopAnalysis). This emitter
  # owns the rebind shape: `heap = py_heappush(heap, item)` etc.

  defp emit_heapq_statement_rebind(heap_name, "heappush", [item_node], context) do
    {item_ast, context} = convert(item_node, context)
    heap_atom = heap_name |> Naming.rewrite() |> String.to_atom()
    heap_ref = {heap_atom, [], nil}
    context = bind_name(context, heap_name)
    {{:=, [], [heap_ref, {:py_heappush, [], [heap_ref, item_ast]}]}, context}
  end

  defp emit_heapq_statement_rebind(heap_name, "heapify", [], context) do
    heap_atom = heap_name |> Naming.rewrite() |> String.to_atom()
    heap_ref = {heap_atom, [], nil}
    context = bind_name(context, heap_name)
    {{:=, [], [heap_ref, {:py_heapify, [], [heap_ref]}]}, context}
  end

  # Emit `raise(RuntimeError, "<ClassName>: <msg>")`. The msg is the
  # first arg (Python convention: `raise ValueError("nope")`). With
  # no args we just stringify the class name. Pylixir doesn't model
  # exception classes, so everything funnels through RuntimeError —
  # callers can still `try/except:` since the existing except is
  # type-agnostic (rescues any).
  defp emit_raise(cls_name, [], context) do
    {{:raise, [], [{:__aliases__, [], [:RuntimeError]}, cls_name]}, context}
  end

  defp emit_raise(cls_name, [msg_node | _], context) do
    {msg_ast, context} = convert(msg_node, context)
    formatted = {:<>, [], [cls_name <> ": ", {:py_str, [], [msg_ast]}]}
    {{:raise, [], [{:__aliases__, [], [:RuntimeError]}, formatted]}, context}
  end

  # --- Operator emission -------------------------------------------------

  defp unary_op_ast(%{"_type" => "UAdd"}, operand_ast, _node), do: operand_ast

  # Constant-fold `-<float-literal>` to the negated literal so IEEE-754
  # negative-zero survives. `py_sub(0, 0.0)` would yield `0.0` (a
  # positive zero) — losing the sign and producing `print(-0.0)` →
  # `"0.0"` instead of Python's `"-0.0"`. Same fold for integer
  # literals so trivial expressions stay readable.
  defp unary_op_ast(%{"_type" => "USub"}, operand_ast, _node) when is_float(operand_ast),
    do: -operand_ast

  defp unary_op_ast(%{"_type" => "USub"}, operand_ast, _node) when is_integer(operand_ast),
    do: -operand_ast

  defp unary_op_ast(%{"_type" => "USub"}, operand_ast, _node), do: {:py_sub, [], [0, operand_ast]}

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
  defp bin_op_ast(%{"_type" => "Sub"}, l, r, _node), do: {:py_sub, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Mult"}, l, r, _node), do: {:py_mult, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Div"}, l, r, _node), do: {:py_div, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Pow"}, l, r, _node), do: {:py_pow, [], [l, r]}
  defp bin_op_ast(%{"_type" => "FloorDiv"}, l, r, _node), do: {:py_floor_div, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Mod"}, l, r, _node), do: {:py_mod, [], [l, r]}
  defp bin_op_ast(%{"_type" => "LShift"}, l, r, _node), do: bitwise_call(:bsl, l, r)
  defp bin_op_ast(%{"_type" => "RShift"}, l, r, _node), do: bitwise_call(:bsr, l, r)
  # Python's `|` / `&` / `^` are overloaded: bitwise on ints, set ops
  # on MapSets. Route through `py_bor` / `py_band` / `py_bxor` helpers
  # which dispatch at runtime. (LShift/RShift stay direct — there's
  # no set equivalent.)
  defp bin_op_ast(%{"_type" => "BitOr"}, l, r, _node), do: {:py_bor, [], [l, r]}
  defp bin_op_ast(%{"_type" => "BitAnd"}, l, r, _node), do: {:py_band, [], [l, r]}
  defp bin_op_ast(%{"_type" => "BitXor"}, l, r, _node), do: {:py_bxor, [], [l, r]}

  defp bin_op_ast(%{"_type" => "MatMult"}, _l, _r, node) do
    raise UnsupportedNodeError,
      node_type: "MatMult",
      hint: "matrix-multiplication operator `@` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp bin_op_ast(%{"_type" => other}, _l, _r, node) do
    raise UnsupportedNodeError,
      node_type: other,
      hint: "binary operator `#{other}` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp bitwise_call(fun_name, l, r) do
    {{:., [], [{:__aliases__, [], [:Bitwise]}, fun_name]}, [], [l, r]}
  end

  defp bool_op_atom(%{"_type" => "And"}, _node), do: :&&
  defp bool_op_atom(%{"_type" => "Or"}, _node), do: :||

  defp bool_op_atom(%{"_type" => other}, node) do
    raise UnsupportedNodeError,
      node_type: other,
      hint: "boolean operator `#{other}` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end


  @doc false
  def bind_name(context, name) when is_binary(name) do
    [head | rest] = context.scopes
    %{context | scopes: [MapSet.put(head, name) | rest]}
  end

  # --- AugAssign dispatch -----------------------------------------------

  defp aug_assign(%{"_type" => "Name", "id" => id}, op, value, node, context) do
    {value_ast, context} = convert(value, context)
    context = bind_name(context, id)
    target_atom = id |> Naming.rewrite() |> String.to_atom()
    target_ref = {target_atom, [], nil}
    rhs = bin_op_ast(op, target_ref, value_ast, node)
    {{:=, [], [target_ref, rhs]}, context}
  end

  defp aug_assign(
         %{"_type" => "Subscript", "value" => collection, "slice" => slice},
         op,
         value,
         node,
         context
       ) do
    {coll_ast, coll_binding, context} = maybe_temp_bind(collection, context)
    {slice_ast, slice_binding, context} = maybe_temp_bind(slice, context)
    {value_ast, context} = convert(value, context)

    getitem = {:py_getitem, [], [coll_ast, slice_ast]}
    combined = bin_op_ast(op, getitem, value_ast, node)
    setitem = {:py_setitem, [], [coll_ast, slice_ast, combined]}

    final =
      case collection do
        %{"_type" => "Name", "id" => coll_id} ->
          bind_name_returning_assign(context, coll_id, coll_ast, setitem)

        _ ->
          {setitem, context}
      end

    {final_ast, context} = final
    bindings = Enum.reject([coll_binding, slice_binding], &is_nil/1)

    result =
      case bindings do
        [] -> final_ast
        _ -> {:__block__, [], bindings ++ [final_ast]}
      end

    {result, context}
  end

  defp aug_assign(target, _op, _value, node, _context) do
    raise UnsupportedNodeError,
      node_type: "AugAssign",
      hint:
        "AugAssign target shape `#{Map.get(target, "_type")}` is not supported (use a Name or Subscript target)",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp bind_name_returning_assign(context, coll_id, coll_ref, setitem) do
    context = bind_name(context, coll_id)
    {{:=, [], [coll_ref, setitem]}, context}
  end

  @doc false
  def var_bound?(context, var) do
    Enum.any?(context.scopes, &MapSet.member?(&1, var))
  end

  # `name_in_scope?` is a synonym kept for readability at the Call-router
  # site (where "name" is the natural term) — they walk the same scopes.
  @doc false
  def name_in_scope?(context, name) do
    Enum.any?(context.scopes, &MapSet.member?(&1, name))
  end

  # --- Call routing (T28) ------------------------------------------------

  # `isinstance(x, T)` consumes T by inspecting the bare-Name shape
  # (`Builtins.isinstance_call/2`). Routing T through the general Name
  # converter would now lower it to a unary builtin capture
  # (e.g. `fn x -> py_int(x) end`), which isinstance can't pattern-match
  # on. Pull T directly out of the Python AST instead. Builtins.emit
  # itself returns `{:error, hint}` for non-bare-Name second args, which
  # `Lowering.dispatch/4` surfaces with the existing hint.
  defp emit_name_call("isinstance", node, context) do
    args = Map.get(node, "args", [])
    {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)

    {emit_args, context} =
      case args do
        [x_node, %{"_type" => "Name", "id" => type_id}] ->
          {x_ast, context} = convert(x_node, context)
          {[x_ast, {String.to_atom(type_id), [], nil}], context}

        _ ->
          convert_each(args, context)
      end

    Lowering.dispatch(
      Builtins.emit("isinstance", emit_args, kwargs),
      "`isinstance/#{length(emit_args)}` is not a supported Python builtin call shape",
      node,
      context
    )
  end

  defp emit_name_call(id, node, context) do
    raw_args = Map.get(node, "args", [])

    case single_starred_args(raw_args) do
      {:ok, star_node} ->
        emit_starred_call(id, star_node, node, context)

      :no ->
        {arg_asts, context} = convert_each(raw_args, context)
        {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)

        cond do
          # `from <mod> import <name>` was lowered to a capture of a
          # fixed arity. If the user calls it with a different arity,
          # bypass the in-scope lambda and dispatch through the stdlib
          # — that callback knows all arities the helper supports.
          Map.has_key?(context.stdlib_aliases, id) ->
            {mod, name} = context.stdlib_aliases[id]
            impl = Stdlib.impl(mod)

            Lowering.dispatch(
              impl.call([name], arg_asts, kwargs, node),
              "`#{id}/#{length(arg_asts)}` (alias for #{mod}.#{name}) is not a supported call shape",
              node,
              context
            )

          id == context.recursive_self_binding ->
            no_kwargs!(kwargs, id, node)
            self_ref = {:self, [], nil}
            {{{:., [], [self_ref]}, [], arg_asts ++ [self_ref]}, context}

          MapSet.member?(context.recursive_lambdas, id) ->
            no_kwargs!(kwargs, id, node)
            atom = id |> Naming.rewrite() |> String.to_atom()
            ref = {atom, [], nil}
            {{{:., [], [ref]}, [], arg_asts ++ [ref]}, context}

          name_in_scope?(context, id) ->
            no_kwargs!(kwargs, id, node)
            atom = id |> Naming.rewrite() |> String.to_atom()
            ref = {atom, [], nil}
            {{{:., [], [ref]}, [], arg_asts}, context}

          Builtins.supported?(id) ->
            Lowering.dispatch(
              Builtins.emit(id, arg_asts, kwargs),
              "`#{id}/#{length(arg_asts)}` is not a supported Python builtin call shape",
              node,
              context
            )

          true ->
            no_kwargs!(kwargs, id, node)
            atom = id |> Naming.rewrite() |> String.to_atom()
            {{atom, [], arg_asts}, context}
        end
    end
  end

  # Recognise the common `f(*args)` shape — a single Starred argument
  # and nothing else. Mixed star + positional (`f(a, *xs, b)`) and
  # multiple stars require list-concat at the call site; not handled.
  defp single_starred_args([%{"_type" => "Starred", "value" => v}]), do: {:ok, v}
  defp single_starred_args(_), do: :no

  # Match `type(x).__name__` precisely: Attribute(value=Call(func=Name("type"),
  # args=[x], no kwargs/star), attr="__name__"). The shape that comes up in
  # real code; anything else (`type(x).__mro__`, `obj.__class__.__name__`, ...)
  # still raises so the failure is loud.
  defp detect_type_name_access(%{
         "_type" => "Attribute",
         "attr" => "__name__",
         "value" => %{
           "_type" => "Call",
           "func" => %{"_type" => "Name", "id" => "type"},
           "args" => [arg],
           "keywords" => []
         }
       }),
       do: {:ok, arg}

  defp detect_type_name_access(_), do: :no

  # `zip(*xs)` is the only builtin that has a list-form lowering matching
  # Python's star-unpack semantics — `Enum.zip(xs)` already iterates a
  # list-of-iters in lockstep, same as `zip(*xs)`. For other in-scope
  # names (lambdas, demoted functions), emit `apply(fn_ref, args)`.
  # Top-level `defp`s — `Kernel.apply(__MODULE__, :name, args)`.
  defp emit_starred_call("zip", star_node, _node, context) do
    {arg_ast, context} = convert(star_node, context)
    {{{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [], [arg_ast]}, context}
  end

  # `print(*xs[, sep=..., end=...])` — unpack and print. Routes to
  # `py_print_iter/3` (sep, end_), which py_str's each elem, joins
  # with sep, and appends end_ via IO.write. Defaults match Python:
  # sep=" ", end="\n". Mixed positional+star forms aren't handled
  # here (the call-site requires a single Starred arg).
  defp emit_starred_call("print", star_node, node, context) do
    {arg_ast, context} = convert(star_node, context)
    {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)
    sep_ast = Map.get(kwargs, "sep", " ")
    end_ast = Map.get(kwargs, "end", "\n")
    {{:py_print_iter, [], [arg_ast, sep_ast, end_ast]}, context}
  end

  defp emit_starred_call(id, star_node, node, context) do
    {arg_ast, context} = convert(star_node, context)
    arg_list = {:py_iter_to_list, [], [arg_ast]}

    cond do
      name_in_scope?(context, id) ->
        # `id` is bound as a lambda — `apply(fn, args)` works.
        atom = id |> Naming.rewrite() |> String.to_atom()
        ref = {atom, [], nil}
        {{{:., [], [{:__aliases__, [], [:Kernel]}, :apply]}, [], [ref, arg_list]}, context}

      MapSet.member?(context.known_functions, id) ->
        # Top-level `def f(...)` — reachable via `apply(__MODULE__, :f, args)`.
        # (Top-level Pylixir functions are public `def`s since the
        # @doc-propagation switch.)
        atom = id |> Naming.rewrite() |> String.to_atom()
        mod = {:__MODULE__, [], nil}
        {{{:., [], [{:__aliases__, [], [:Kernel]}, :apply]}, [], [mod, atom, arg_list]}, context}

      true ->
        raise UnsupportedNodeError,
          node_type: "Starred",
          hint:
            "`#{id}(*args)` is only supported when `#{id}` is in scope as a lambda, a top-level def, or the builtin `zip`",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  # Chained-call shape: `f(x)(y)`, `(lambda x: ...)(arg)`, etc.
  # The `func` is itself an expression (Call/Lambda/Subscript/IfExp)
  # that returns a callable. Emit `(callable_ast).(args)` — Elixir's
  # anonymous-call invocation. Kwargs unsupported: Python's calling
  # convention here matches the in-scope-lambda call path, which also
  # doesn't accept kwargs.
  defp emit_dynamic_call(node, context) do
    {callable_ast, context} = convert(node["func"], context)
    {arg_asts, context} = convert_each(Map.get(node, "args", []), context)

    case Map.get(node, "keywords", []) do
      [] ->
        {{{:., [], [callable_ast]}, [], arg_asts}, context}

      _ ->
        raise UnsupportedNodeError,
          node_type: "Call",
          hint: "chained call with kwargs (`f(x)(y, k=v)`) is not supported",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  defp emit_attribute_call(target, attr, node, context) do
    # Stdlib root? `target` is the chain *before* the method name; the
    # full path is that prefix plus the method `attr`. Examples:
    # `math.sqrt(4)`: target=Name("math"), prefix=[], path=["sqrt"].
    # `sys.stdin.read()`: target=Attribute(sys, "stdin"), prefix=["stdin"],
    # path=["stdin", "read"].
    synthesized = %{"_type" => "Attribute", "value" => target, "attr" => attr}

    case stdlib_chain(synthesized) do
      {:ok, mod_name, path} ->
        {arg_asts, context} = convert_each(Map.get(node, "args", []), context)
        {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)
        impl = Stdlib.impl(mod_name)

        Lowering.dispatch(
          impl.call(path, arg_asts, kwargs, node),
          "`#{mod_name}.#{Enum.join(path, ".")}` is not a supported stdlib call",
          node,
          context
        )

      :no_stdlib ->
        {target_ast, context} = convert(target, context)
        {arg_asts, context} = convert_each(Map.get(node, "args", []), context)
        {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)
        {Nodes.AttributeMethods.dispatch(attr, target_ast, arg_asts, kwargs, node), context}
    end
  end

  # Walk an Attribute chain; if the root is a Name matching a registered
  # `Pylixir.Stdlib` module, return `{:ok, mod_name, attr_path}` where
  # `attr_path` is the list of attribute names *after* the module
  # (always ≥ 1 element since the input is an Attribute node, not a
  # bare Name). Anything else returns `:no_stdlib`.
  defp stdlib_chain(%{"_type" => "Attribute", "value" => value, "attr" => attr}) do
    case attribute_root(value, [attr]) do
      {:ok, root, path} ->
        if Stdlib.supported?(root), do: {:ok, root, path}, else: :no_stdlib

      :error ->
        :no_stdlib
    end
  end

  defp attribute_root(%{"_type" => "Name", "id" => id}, acc), do: {:ok, id, acc}

  defp attribute_root(%{"_type" => "Attribute", "value" => v, "attr" => a}, acc),
    do: attribute_root(v, [a | acc])

  defp attribute_root(_, _), do: :error

  @doc false
  def convert_keywords([], context), do: {%{}, context}

  def convert_keywords(keywords, context) do
    Enum.reduce(keywords, {%{}, context}, fn
      %{"arg" => nil}, _ ->
        raise UnsupportedNodeError,
          node_type: "Call",
          hint: "double-star kwargs unpack (**d) at call sites is not supported"

      %{"arg" => name, "value" => value}, {acc, ctx} ->
        {ast, ctx} = convert(value, ctx)
        {Map.put(acc, name, ast), ctx}
    end)
  end

  defp no_kwargs!(kwargs, _id, _node) when map_size(kwargs) == 0, do: :ok

  defp no_kwargs!(_kwargs, id, node) do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint: "keyword arguments at call sites are not supported for `#{id}`",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  @doc false
  def tuple_pattern([a, b]), do: {a, b}
  def tuple_pattern(refs), do: {:{}, [], refs}

  @doc false
  # Python's throwaway names (`_`, `__`, `___`, …) — emit Elixir's
  # discard pattern, don't bind, don't return in the `names` list.
  # See `LoopAnalysis.discard_name?/1` for the matching exclusion and
  # rationale (Elixir's `_` is pattern-only; `__` collides with the
  # compiler-variable prefix).
  def convert_loop_target(%{"_type" => "Name", "id" => id}, context)
      when is_binary(id) and id != "" do
    context = bind_name(context, id)
    atom = id |> Naming.rewrite() |> String.to_atom()
    # All-underscore Python names rewrite to `_us`/`_us2`/... — valid
    # Elixir bindings that suppress the unused-variable warning via
    # the `_` prefix. They're still excluded from the threading
    # set in `LoopAnalysis.discard_name?` so they don't leak into
    # state tuples.
    names = if all_underscores?(id), do: [], else: [id]
    {{atom, [], nil}, names, context}
  end

  def convert_loop_target(%{"_type" => "Tuple", "elts" => elts}, context) do
    reject_starred!(elts, "Tuple")

    {refs, names, context} =
      Enum.reduce(elts, {[], [], context}, fn elt, {refs, names, ctx} ->
        {ref, new_names, ctx} = convert_loop_target_elt(elt, ctx)
        {[ref | refs], Enum.reverse(new_names) ++ names, ctx}
      end)

    {tuple_pattern(Enum.reverse(refs)), Enum.reverse(names), context}
  end

  def convert_loop_target(target, _context) do
    raise UnsupportedNodeError,
      node_type: "For",
      hint:
        "for-loop target shape `#{Map.get(target, "_type")}` is not supported (use a Name or Tuple of Names)"
  end

  defp all_underscores?(id),
    do: id |> String.to_charlist() |> Enum.all?(&(&1 == ?_))

  # Per-element helper for tuple-target recursion. Allows nested
  # tuples of Names — `for (a, b), c in pairs:` / `for (r, c), v in
  # bonuses.items():` etc. Each Name is treated like the single-Name
  # case (discard-rules, scope binding); each nested Tuple recurses.
  defp convert_loop_target_elt(%{"_type" => "Name", "id" => id}, context)
       when is_binary(id) and id != "" do
    context = bind_name(context, id)
    atom = id |> Naming.rewrite() |> String.to_atom()
    names = if all_underscores?(id), do: [], else: [id]
    {{atom, [], nil}, names, context}
  end

  defp convert_loop_target_elt(%{"_type" => "Tuple", "elts" => inner_elts}, context) do
    reject_starred!(inner_elts, "Tuple")

    {refs, names, context} =
      Enum.reduce(inner_elts, {[], [], context}, fn elt, {refs, names, ctx} ->
        {ref, new_names, ctx} = convert_loop_target_elt(elt, ctx)
        {[ref | refs], Enum.reverse(new_names) ++ names, ctx}
      end)

    {tuple_pattern(Enum.reverse(refs)), Enum.reverse(names), context}
  end

  defp convert_loop_target_elt(other, _context) do
    raise UnsupportedNodeError,
      node_type: "For",
      hint:
        "for-loop tuple-target element must be a Name or nested Tuple of Names; got `#{Map.get(other, "_type")}`"
  end

  @doc false
  def convert_test(test_node, context) do
    {test_ast, context} = convert(test_node, context)

    wrapped =
      if BoolReturning.bool_returning?(test_node) do
        test_ast
      else
        {:truthy?, [], [test_ast]}
      end

    {wrapped, context}
  end

  @doc false
  def body_to_block([]), do: nil
  def body_to_block([single]), do: single
  def body_to_block(many), do: {:__block__, [], many}

  @doc false
  def maybe_temp_bind(node, context) do
    {ast, context} = convert(node, context)

    if Trivial.trivial?(node) do
      {ast, nil, context}
    else
      {temp_atom, context} = next_temp(context)
      temp_ref = {temp_atom, [], nil}
      {temp_ref, {:=, [], [temp_ref, ast]}, context}
    end
  end

  @doc false
  def next_temp(context) do
    n = context.temp_counter
    atom = String.to_atom("py_tmp_#{n}")
    {atom, %{context | temp_counter: n + 1}}
  end


  # --- Literal-container rejections --------------------------------------

  defp convert_del_target(
         %{
           "_type" => "Subscript",
           "value" => %{"_type" => "Name", "id" => coll_id} = collection,
           "slice" => slice
         },
         _node,
         context
       ) do
    {slice_ast, context} = convert(slice, context)
    {coll_ast, context} = convert(collection, context)
    context = bind_name(context, coll_id)
    {{:=, [], [coll_ast, {:py_delitem, [], [coll_ast, slice_ast]}]}, context}
  end

  defp convert_del_target(other, node, _context) do
    raise UnsupportedNodeError,
      node_type: "Delete",
      hint:
        "`del` target shape `#{Map.get(other, "_type")}` is not supported (only depth-1 subscript on a bare Name)",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # `from <stdlib_mod> import <name> [as <alias>]` — delegates the
  # per-name RHS shape to the stdlib's `import_binding/1` callback.
  # The Converter only owns the alias-tracking + AST assembly here;
  # what each name actually binds to lives in `Pylixir.Stdlib.<Mod>`.
  defp stdlib_from_import_alias(mod, impl, name, alias, context, node) do
    alias_atom = alias |> Naming.rewrite() |> String.to_atom()
    alias_ref = {alias_atom, [], nil}

    rhs =
      case impl.import_binding(name) do
        {:ok, ast} ->
          ast

        :error ->
          raise UnsupportedNodeError,
            node_type: "ImportFrom",
            hint: "`from #{mod} import #{name}` is not supported",
            lineno: Map.get(node, "lineno"),
            col_offset: Map.get(node, "col_offset")
      end

    context = bind_name(context, alias)
    # Remember the stdlib origin so call sites can route through the
    # stdlib's call/4 callback when the user passes more args than the
    # captured arity. Lets `permutations(a, 3)` work after
    # `from itertools import permutations` despite our capture being
    # `&py_permutations/1`.
    context = %{context | stdlib_aliases: Map.put(context.stdlib_aliases, alias, {mod, name})}
    {{:=, [], [alias_ref, rhs]}, context}
  end

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

  # `{**d1, "k": v, **d2}` — walks keys/values in source order, batches
  # consecutive non-unpack pairs into one literal map, then chains
  # `Map.merge` calls across the batches. `keys` entries are `nil` at
  # unpack positions; the matching `values` entry is the dict to spread.
  defp emit_dict_with_unpack(keys, values, context) do
    {groups, context} = build_dict_unpack_groups(Enum.zip(keys, values), context, [], [])

    case groups do
      [single] ->
        {single, context}

      [first | rest] ->
        merged =
          Enum.reduce(rest, first, fn group, acc ->
            {{:., [], [{:__aliases__, [], [:Map]}, :merge]}, [], [acc, group]}
          end)

        {merged, context}
    end
  end

  defp build_dict_unpack_groups([], context, current_pairs, acc),
    do: {Enum.reverse(flush_dict_group(current_pairs, acc)), context}

  defp build_dict_unpack_groups([{nil, unpack_value} | rest], context, current_pairs, acc) do
    {unpack_ast, context} = convert(unpack_value, context)
    acc = flush_dict_group(current_pairs, acc)
    build_dict_unpack_groups(rest, context, [], [unpack_ast | acc])
  end

  defp build_dict_unpack_groups([{key, value} | rest], context, current_pairs, acc) do
    {key_ast, context} = convert(key, context)
    {value_ast, context} = convert(value, context)
    build_dict_unpack_groups(rest, context, [{key_ast, value_ast} | current_pairs], acc)
  end

  defp flush_dict_group([], acc), do: acc
  defp flush_dict_group(pairs, acc), do: [{:%{}, [], Enum.reverse(pairs)} | acc]

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
    # ModuleAnalysis only promotes values that `Pylixir.LiteralFold` can
    # evaluate, so the fold here is guaranteed to succeed — bypassing
    # `convert/2` (which would emit runtime helper calls invalid at
    # module-attribute scope) is the whole reason promotion exists.
    {:ok, value} = Pylixir.LiteralFold.fold(value_node)
    value_ast = Macro.escape(value)
    attr = {:@, [], [{:"var_#{name}", [], [value_ast]}]}
    {rest_asts, context} = convert_module_attrs(rest, context)
    {[attr | rest_asts], context}
  end

  @doc false
  def convert_optional(nil, context), do: {nil, context}
  def convert_optional(node, context), do: convert(node, context)

  @doc false
  def convert_each(nodes, context) do
    {asts, context} =
      Enum.reduce(nodes, {[], context}, fn node, {acc, ctx} ->
        {ast, ctx} = convert(node, ctx)
        {[ast | acc], ctx}
      end)

    {Enum.reverse(asts), context}
  end

  # `@moduledoc "..."` from a Python module-level docstring. Returns
  # an empty list when no docstring was extracted so callers can splice
  # unconditionally.
  defp moduledoc_ast(nil), do: []
  defp moduledoc_ast(doc) when is_binary(doc), do: [{:@, [], [{:moduledoc, [], [doc]}]}]

  defp py_main_def([]) do
    {:def, [], [{:py_main, [], nil}, [do: nil]]}
  end

  defp py_main_def([single]) do
    {:def, [], [{:py_main, [], nil}, [do: wrap_exit_catch(single)]]}
  end

  defp py_main_def(many) do
    {:def, [], [{:py_main, [], nil}, [do: wrap_exit_catch({:__block__, [], many})]]}
  end

  # py_main catches `{:pylixir_exit, code}` so Python's `exit(code)`
  # (lowered to a throw by `Builtins.emit("exit", ...)`) returns the code
  # instead of killing the process. Always wrapped — the runtime cost is
  # one stack frame, and conditional wrapping would need a Module-scope
  # exit-usage scan.
  defp wrap_exit_catch(body) do
    code_ref = {:code, [], nil}
    catch_clause = ControlFlow.catch_exit(code_ref, code_ref)
    {:try, [], [[do: body, catch: [catch_clause]]]}
  end
end
