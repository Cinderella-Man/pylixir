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

  # `from math import gcd, sqrt, ...` — emit each name as a local
  # lambda that delegates to the matching `Pylixir.Stdlib.Math` AST.
  # Subsequent calls go through the in-scope-anonymous-call path
  # (`gcd.(t, n)` etc.). Unsupported math names raise.
  # `from functools import lru_cache, cache` — both are decorator
  # no-ops in Pylixir (we don't memoize; functions just re-compute).
  # Bind each imported name to an identity wrapper so user code that
  # passes the decorator around without using it (`d = lru_cache(...)`
  # then `@d`) still resolves. The decorator path itself is stripped
  # in `Pylixir.Nodes.Functions.safe_to_strip_decorator?/1`.
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

  def convert(%{"_type" => "ImportFrom", "module" => mod, "names" => names} = node, context)
      when mod in ~w(math sys bisect heapq itertools) do
    {stmts, context} =
      Enum.reduce(names, {[], context}, fn entry, {acc, ctx} ->
        n = entry["name"]
        alias = entry["asname"] || n
        {stmt, ctx} = stdlib_from_import_alias(mod, n, alias, ctx, node)
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

  # `from collections import deque` — silent no-op. `deque` is then
  # used as a bare name and translated as a builtin (`deque()` →
  # `[]`, `deque(iter)` → `Enum.to_list(iter)`). Other collections
  # symbols (Counter, defaultdict, …) fall through to the catch-all.
  def convert(%{"_type" => "ImportFrom", "module" => "collections", "names" => names}, context) do
    allowed = ~w(deque Counter defaultdict)

    unknown = Enum.find(names, fn %{"name" => n} -> n not in allowed end)

    if unknown do
      raise UnsupportedNodeError,
        node_type: "ImportFrom",
        hint:
          "`from collections import #{unknown["name"]}` is not supported (allowed: #{Enum.join(allowed, ", ")})"
    end

    {{:__block__, [], []}, context}
  end

  def convert(%{"_type" => "ImportFrom", "module" => mod}, _context) do
    raise UnsupportedNodeError,
      node_type: "ImportFrom",
      hint:
        "`from #{mod} import ...` is not supported (only `from __future__`; for stdlib modules use `import #{mod}` and reference via `#{mod}.<name>`)"
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
        target_type = Map.get(node["value"], "_type")

        raise UnsupportedNodeError,
          node_type: "Attribute",
          hint:
            "attribute access on a non-stdlib value (`<#{target_type}>.#{attr}`) is not supported (known stdlib modules: #{Enum.join(Stdlib.names(), ", ")})",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
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
    case heapq_statement_mutation(value, context) do
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

  def convert(%{"_type" => "Assign", "targets" => targets, "value" => value} = node, context) do
    case targets do
      [single] -> single_target_assign(single, rewrite_stdlib_alias_call(value, context), node, context)
      _ -> multi_target_assign(targets, value, node, context)
    end
  end

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

  def convert(%{"_type" => "Dict", "keys" => keys, "values" => values} = node, context) do
    reject_dict_unpack!(keys, node)
    {key_asts, context} = convert_each(keys, context)
    {value_asts, context} = convert_each(values, context)
    pairs = Enum.zip(key_asts, value_asts)
    {{:%{}, [], pairs}, context}
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

      MapSet.member?(context.module_attrs, id) ->
        attr_name = String.to_atom("var_" <> id)
        {{:@, [], [{attr_name, [], nil}]}, context}

      not name_in_scope?(context, id) and Builtins.unary_capturable?(id) ->
        {Builtins.unary_capture(id), context}

      true ->
        atom = id |> Naming.rewrite() |> String.to_atom()
        {{atom, [], nil}, context}
    end
  end

  # f-strings: `f"x={x} y={y}"` lowers to `py_str(x) <> "x=" <> py_str(y) …`.
  # Each `FormattedValue` becomes `py_str(value)`; plain `Constant`
  # children stay as their binary value. Format specs are not yet
  # supported (`f"{x:.2f}"` raises — use `"{:.2f}".format(x)` for now).
  def convert(%{"_type" => "JoinedStr", "values" => values}, context) do
    {parts, context} =
      Enum.reduce(values, {[], context}, fn part, {acc, ctx} ->
        {ast, ctx} = joined_str_part(part, ctx)
        {[ast | acc], ctx}
      end)

    parts = Enum.reverse(parts)

    ast =
      case parts do
        [] -> ""
        [single] -> single
        [first | rest] -> Enum.reduce(rest, first, fn p, acc -> {:<>, [], [acc, p]} end)
      end

    {ast, context}
  end

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

  # --- heapq statement-mutation helpers (called from the Expr clause) ---

  # Recognise `heapq.heappush(heap, item)` and `heapq.heapify(heap)`
  # at statement position. Both are documented as in-place mutations
  # in Python; the rebind happens here so user code can keep its
  # `heap = []; heapq.heappush(heap, x)` shape verbatim.
  defp heapq_statement_mutation(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => "heapq"},
             "attr" => method
           },
           "args" => [%{"_type" => "Name", "id" => heap_name} | rest]
         },
         _context
       )
       when method in ["heappush", "heapify"] do
    {:ok, heap_name, method, rest}
  end

  # Bare-Name `heappush(h, x)` / `heapify(h)` after `from heapq import ...`
  # — route through the same rebind logic as `heapq.X(...)` so the user's
  # `heap = []; heappush(heap, x)` shape works.
  defp heapq_statement_mutation(
         %{
           "_type" => "Call",
           "func" => %{"_type" => "Name", "id" => alias},
           "args" => [%{"_type" => "Name", "id" => heap_name} | rest]
         },
         context
       ) do
    case context.stdlib_aliases[alias] do
      {"heapq", method} when method in ["heappush", "heapify"] ->
        {:ok, heap_name, method, rest}

      _ ->
        :none
    end
  end

  defp heapq_statement_mutation(_, _), do: :none

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

  # `.pop()` family RHS — picks the right runtime helper based on arity.
  # 0 args → last element / KeyError on dict (we use py_pop_last for lists);
  # 1 arg  → index for lists, key for dicts; 2 args → key + default for dicts.
  defp pop_call_rhs(coll_ref, []), do: {:py_pop_last, [], [coll_ref]}
  defp pop_call_rhs(coll_ref, [a]), do: {:py_pop_at, [], [coll_ref, a]}
  defp pop_call_rhs(coll_ref, [a, b]), do: {:py_pop_at_default, [], [coll_ref, a, b]}

  # --- Operator emission -------------------------------------------------

  defp unary_op_ast(%{"_type" => "UAdd"}, operand_ast, _node), do: operand_ast
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

  # --- Assign target dispatch -------------------------------------------

  # `x = coll.pop()` / `x = coll.pop(idx_or_key)` / `.pop(key, default)`
  # — Python's mutating capture-and-return pop. Lowers to a
  # `{popped, coll} = py_pop_<…>(coll, …)` destructure-match so the
  # collection is rebound in one shot. py_pop_* branch on container
  # type at runtime: list (index-based) vs dict (key-based).
  defp single_target_assign(
         %{"_type" => "Name", "id" => id},
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => coll_id},
             "attr" => "pop"
           },
           "args" => args
         },
         _node,
         context
       )
       when length(args) <= 2 do
    {arg_asts, context} = Enum.map_reduce(args, context, &convert/2)
    context = bind_name(context, id)
    context = bind_name(context, coll_id)
    head_atom = id |> Naming.rewrite() |> String.to_atom()
    coll_atom = coll_id |> Naming.rewrite() |> String.to_atom()
    head_ref = {head_atom, [], nil}
    coll_ref = {coll_atom, [], nil}
    rhs = pop_call_rhs(coll_ref, arg_asts)
    {{:=, [], [{head_ref, coll_ref}, rhs]}, context}
  end

  # Tuple-destructure variant: `a, b = coll.pop()` — the popped value
  # is itself a tuple, so the head pattern destructures further.
  defp single_target_assign(
         %{"_type" => "Tuple", "elts" => elts},
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => coll_id},
             "attr" => "pop"
           },
           "args" => args
         },
         _node,
         context
       )
       when length(args) <= 2 do
    Enum.each(elts, fn
      %{"_type" => "Name"} ->
        :ok

      other ->
        raise UnsupportedNodeError,
          node_type: "Assign",
          hint:
            "tuple-destructure of `.pop()` requires Name elements; got `#{Map.get(other, "_type")}`"
    end)

    {arg_asts, context} = Enum.map_reduce(args, context, &convert/2)
    context = bind_tuple_names!(elts, context)
    context = bind_name(context, coll_id)

    refs =
      Enum.map(elts, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    head_pattern = tuple_pattern(refs)
    coll_atom = coll_id |> Naming.rewrite() |> String.to_atom()
    coll_ref = {coll_atom, [], nil}
    rhs = pop_call_rhs(coll_ref, arg_asts)
    {{:=, [], [{head_pattern, coll_ref}, rhs]}, context}
  end

  # `x = q.popleft()` — Python's deque.popleft returns the leftmost
  # element AND removes it. Pylixir's deque-as-list rep lowers to a
  # cons-pattern destructure: `[x | q] = q` binds `x` to the head and
  # rebinds `q` to the tail in one match. Runtime crash on empty list
  # (Python raises `IndexError`; close enough).
  defp single_target_assign(
         %{"_type" => "Name", "id" => id},
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => coll_id},
             "attr" => "popleft"
           },
           "args" => args
         },
         _node,
         context
       )
       when args == [] do
    context = bind_name(context, id)
    context = bind_name(context, coll_id)
    head_atom = id |> Naming.rewrite() |> String.to_atom()
    coll_atom = coll_id |> Naming.rewrite() |> String.to_atom()
    head_ref = {head_atom, [], nil}
    coll_ref = {coll_atom, [], nil}
    pattern = [{:|, [], [head_ref, coll_ref]}]
    {{:=, [], [pattern, coll_ref]}, context}
  end

  # `x = heapq.heappop(heap)` — py_heappop returns `{head, tail}`, so
  # the Assign rebinds BOTH `x` (head) and `heap` (tail) in one
  # destructure-match.
  defp single_target_assign(
         %{"_type" => "Name", "id" => id},
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => "heapq"},
             "attr" => "heappop"
           },
           "args" => [%{"_type" => "Name", "id" => heap_name}]
         },
         _node,
         context
       ) do
    context = bind_name(context, id)
    context = bind_name(context, heap_name)
    head_atom = id |> Naming.rewrite() |> String.to_atom()
    heap_atom = heap_name |> Naming.rewrite() |> String.to_atom()
    head_ref = {head_atom, [], nil}
    heap_ref = {heap_atom, [], nil}
    {{:=, [], [{head_ref, heap_ref}, {:py_heappop, [], [heap_ref]}]}, context}
  end

  defp single_target_assign(
         %{"_type" => "Tuple", "elts" => elts},
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => "heapq"},
             "attr" => "heappop"
           },
           "args" => [%{"_type" => "Name", "id" => heap_name}]
         },
         _node,
         context
       ) do
    Enum.each(elts, fn
      %{"_type" => "Name"} ->
        :ok

      other ->
        raise UnsupportedNodeError,
          node_type: "Assign",
          hint:
            "tuple-destructure of `heapq.heappop()` requires Name elements; got `#{Map.get(other, "_type")}`"
    end)

    context = bind_tuple_names!(elts, context)
    context = bind_name(context, heap_name)

    head_refs =
      Enum.map(elts, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    head_pattern = tuple_pattern(head_refs)
    heap_atom = heap_name |> Naming.rewrite() |> String.to_atom()
    heap_ref = {heap_atom, [], nil}
    {{:=, [], [{head_pattern, heap_ref}, {:py_heappop, [], [heap_ref]}]}, context}
  end

  # `x, y = q.popleft()` — tuple-destructure of the deque-head value.
  # Same cons-pattern as the Name case, but the head pattern is a
  # Names-only tuple. (Subscript elements in this position aren't
  # supported — Python rarely uses them either.)
  defp single_target_assign(
         %{"_type" => "Tuple", "elts" => elts},
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => coll_id},
             "attr" => "popleft"
           },
           "args" => []
         },
         _node,
         context
       ) do
    Enum.each(elts, fn
      %{"_type" => "Name"} ->
        :ok

      other ->
        raise UnsupportedNodeError,
          node_type: "Assign",
          hint:
            "tuple-destructure of `popleft()` requires all targets to be Name; got `#{Map.get(other, "_type")}`"
    end)

    context = bind_tuple_names!(elts, context)
    context = bind_name(context, coll_id)

    refs =
      Enum.map(elts, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    head_pattern = tuple_pattern(refs)
    coll_atom = coll_id |> Naming.rewrite() |> String.to_atom()
    coll_ref = {coll_atom, [], nil}
    pattern = [{:|, [], [head_pattern, coll_ref]}]
    {{:=, [], [pattern, coll_ref]}, context}
  end

  # `head, *tail = expr` — Python star-unpack destructure. Lower to a
  # `[head | tail] = list` cons-pattern when the star is at the end
  # and the prefix is all Names. Multi-element prefix uses Enum.split.
  # The shape `*a, b` (star not at end) and `a, *b, c` (star in middle)
  # require more general slicing — supported via Enum.split as well.
  defp single_target_assign(%{"_type" => "Tuple", "elts" => elts}, value, node, context) do
    case starred_partition(elts) do
      {:starred, before, star_name, after_elts} ->
        if Enum.all?(before, &match?(%{"_type" => "Name"}, &1)) and
             Enum.all?(after_elts, &match?(%{"_type" => "Name"}, &1)) do
          emit_starred_destructure(before, star_name, after_elts, value, context)
        else
          raise UnsupportedNodeError,
            node_type: "Assign",
            hint: "star-unpack destructure (`a, *b = ...`) requires Name targets",
            lineno: Map.get(node, "lineno"),
            col_offset: Map.get(node, "col_offset")
        end

      :no_star ->
        cond do
          pure_destructure_target?(elts) ->
            # Pure tuple-of-Names (possibly nested) — e.g.
            # `a, b = (1, 2)` or `count, (a, b) = func()`.
            {value_ast, context} = convert(value, context)
            context = bind_destructure_target(elts, context)
            pattern = destructure_pattern(elts)
            {{:=, [], [pattern, value_ast]}, context}

          true ->
            # Mixed Name/Subscript targets (e.g. the swap idiom
            # `t[i], t[i+1] = t[i+1], t[i]`). Can't use Elixir's
            # destructure-match because Subscript isn't a valid pattern.
            # Strategy: temp-bind every RHS value once (single-eval), then
            # apply each LHS in order — Names become normal binds, Subscripts
            # become py_setitem rebinds of the root.
            emit_mixed_tuple_assign(elts, value, node, context)
        end
    end
  end

  defp single_target_assign(
         %{
           "_type" => "Subscript",
           "value" => %{"_type" => "Name", "id" => coll_id} = collection,
           "slice" => slice
         },
         value,
         _node,
         context
       ) do
    case slice do
      # Slice-assignment: `coll[start:stop:step] = new_seq`. Lowers to a
      # rebind of `coll` via `py_slice_assign` (handles both stepped and
      # contiguous cases — len(new_seq) != slice_len is allowed only
      # without a step, per Python semantics).
      %{"_type" => "Slice"} = slice_node ->
        {value_ast, context} = convert(value, context)
        {start_ast, context} = convert_optional(Map.get(slice_node, "lower"), context)
        {stop_ast, context} = convert_optional(Map.get(slice_node, "upper"), context)
        {step_ast, context} = convert_optional(Map.get(slice_node, "step"), context)
        {coll_ast, context} = convert(collection, context)
        rhs = {:py_slice_assign, [], [coll_ast, start_ast, stop_ast, step_ast, value_ast]}
        context = bind_name(context, coll_id)
        {{:=, [], [coll_ast, rhs]}, context}

      _ ->
        {value_ast, context} = convert(value, context)
        {slice_ast, context} = convert(slice, context)
        {coll_ast, context} = convert(collection, context)
        setitem = {:py_setitem, [], [coll_ast, slice_ast, value_ast]}
        context = bind_name(context, coll_id)
        {{:=, [], [coll_ast, setitem]}, context}
    end
  end

  # Nested-subscript assign: `m[a][b]...[z] = v` where the chain bottoms
  # out at a bare Name. Rebind the root via nested `py_setitem` /
  # `py_getitem`. Each slice is temp-bound for single-eval; the root
  # itself is always a Name so it's trivially re-readable. Chains that
  # bottom out at anything else (Attribute, Call, …) fall through to
  # the catch-all.
  defp single_target_assign(
         %{"_type" => "Subscript", "value" => %{"_type" => "Subscript"}} = target,
         value,
         node,
         context
       ) do
    case nested_subscript_chain(target, []) do
      {:ok, coll_id, slices} ->
        emit_nested_subscript_assign(coll_id, slices, value, context)

      :error ->
        raise UnsupportedNodeError,
          node_type: "Assign",
          hint:
            "Nested-subscript assign `<#{target_root_type(target)}>[…][…] = v` is not supported — only chains rooted at a bare Name are",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  defp single_target_assign(%{"_type" => "Name", "id" => id} = target, value, _node, context) do
    {value_ast, context} = convert(value, context)
    context = bind_name(context, id)
    {target_ast, context} = convert(target, context)
    {{:=, [], [target_ast, value_ast]}, context}
  end

  defp single_target_assign(target, _value, node, _context) do
    raise UnsupportedNodeError,
      node_type: "Assign",
      hint:
        "Assign target shape `#{Map.get(target, "_type")}` is not supported in T13 (non-Name-rooted subscript / Attribute / Starred / slice)",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # If the Call's callee is a stdlib alias (recorded via `from <mod>
  # import <name>`), rewrite it to the equivalent `Attribute` shape
  # (`<mod>.<name>`). Lets the existing pattern-matching clauses in
  # `single_target_assign` (which only know the `<mod>.<name>` shape)
  # also work for bare-Name aliased calls. No-op for everything else.
  defp rewrite_stdlib_alias_call(
         %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => alias}} = call,
         context
       ) do
    case context.stdlib_aliases[alias] do
      {mod, name} ->
        attr_func = %{
          "_type" => "Attribute",
          "value" => %{"_type" => "Name", "id" => mod},
          "attr" => name
        }

        Map.put(call, "func", attr_func)

      _ ->
        call
    end
  end

  defp rewrite_stdlib_alias_call(value, _context), do: value

  # --- Nested-tuple destructure helpers (`count, (a, b) = func()`) -------

  # Pure destructure: every leaf is a Name; nested Tuples/Lists are
  # transparent. Matches Python `count, (a, b) = ...` semantics.
  defp pure_destructure_target?(elts) when is_list(elts) do
    Enum.all?(elts, &pure_destructure_elt?/1)
  end

  defp pure_destructure_elt?(%{"_type" => "Name"}), do: true
  defp pure_destructure_elt?(%{"_type" => "Tuple", "elts" => inner}), do: pure_destructure_target?(inner)
  defp pure_destructure_elt?(%{"_type" => "List", "elts" => inner}), do: pure_destructure_target?(inner)
  defp pure_destructure_elt?(_), do: false

  defp bind_destructure_target(elts, context) when is_list(elts) do
    Enum.reduce(elts, context, fn
      %{"_type" => "Name", "id" => id}, ctx -> bind_name(ctx, id)
      %{"_type" => "Tuple", "elts" => inner}, ctx -> bind_destructure_target(inner, ctx)
      %{"_type" => "List", "elts" => inner}, ctx -> bind_destructure_target(inner, ctx)
    end)
  end

  defp destructure_pattern(elts) when is_list(elts) do
    refs = Enum.map(elts, &destructure_elt/1)
    tuple_pattern(refs)
  end

  defp destructure_elt(%{"_type" => "Name", "id" => id}),
    do: {id |> Naming.rewrite() |> String.to_atom(), [], nil}

  defp destructure_elt(%{"_type" => "Tuple", "elts" => inner}), do: destructure_pattern(inner)
  defp destructure_elt(%{"_type" => "List", "elts" => inner}), do: destructure_pattern(inner)

  # --- Starred-destructure helpers (`a, *b, c = expr`) -------------------

  defp starred_partition(elts) do
    case Enum.split_with(elts, &match?(%{"_type" => "Starred"}, &1)) do
      {[], _} ->
        :no_star

      {[_one], _rest} ->
        idx = Enum.find_index(elts, &match?(%{"_type" => "Starred"}, &1))
        {before, [starred | after_elts]} = Enum.split(elts, idx)
        %{"value" => %{"_type" => "Name", "id" => star_name}} = starred
        {:starred, before, star_name, after_elts}

      _ ->
        :no_star
    end
  end

  defp emit_starred_destructure([], star_name, [], value, context) do
    {value_ast, context} = convert(value, context)
    star_atom = star_name |> Naming.rewrite() |> String.to_atom()
    context = bind_name(context, star_name)
    rhs = {:py_iter_to_list, [], [value_ast]}
    {{:=, [], [{star_atom, [], nil}, rhs]}, context}
  end

  defp emit_starred_destructure(before, star_name, [], value, context) do
    {value_ast, context} = convert(value, context)
    {temp_atom, context} = next_temp(context)
    temp_ref = {temp_atom, [], nil}
    to_list = {:py_iter_to_list, [], [value_ast]}
    bind_temp = {:=, [], [temp_ref, to_list]}

    n_before = length(before)
    star_atom = star_name |> Naming.rewrite() |> String.to_atom()

    before_pattern =
      Enum.map(before, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    context = Enum.reduce(before, context, fn %{"_type" => "Name", "id" => id}, ctx -> bind_name(ctx, id) end)
    context = bind_name(context, star_name)

    split = {{:., [], [{:__aliases__, [], [:Enum]}, :split]}, [], [temp_ref, n_before]}
    bind_split = {:=, [], [{before_pattern, {star_atom, [], nil}}, split]}
    {{:__block__, [], [bind_temp, bind_split]}, context}
  end

  defp emit_starred_destructure(before, star_name, after_elts, value, context) do
    {value_ast, context} = convert(value, context)
    {temp_atom, context} = next_temp(context)
    temp_ref = {temp_atom, [], nil}
    to_list = {:py_iter_to_list, [], [value_ast]}
    bind_temp = {:=, [], [temp_ref, to_list]}

    n_before = length(before)
    n_after = length(after_elts)
    star_atom = star_name |> Naming.rewrite() |> String.to_atom()

    context =
      Enum.reduce(before ++ after_elts, context, fn %{"_type" => "Name", "id" => id}, ctx ->
        bind_name(ctx, id)
      end)

    context = bind_name(context, star_name)

    before_pat =
      Enum.map(before, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    after_pat =
      Enum.map(after_elts, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    {temp2_atom, context} = next_temp(context)
    temp2_ref = {temp2_atom, [], nil}

    split1 = {{:., [], [{:__aliases__, [], [:Enum]}, :split]}, [], [temp_ref, n_before]}
    bind_split1 = {:=, [], [{before_pat, temp2_ref}, split1]}

    len_temp2 = {{:., [], [{:__aliases__, [], [:Kernel]}, :length]}, [], [temp2_ref]}
    n_star = {:-, [], [len_temp2, n_after]}
    split2 = {{:., [], [{:__aliases__, [], [:Enum]}, :split]}, [], [temp2_ref, n_star]}
    bind_split2 = {:=, [], [{{star_atom, [], nil}, after_pat}, split2]}

    {{:__block__, [], [bind_temp, bind_split1, bind_split2]}, context}
  end

  defp multi_target_assign(targets, value, node, context) do
    # Validate target shapes early — reject anything we don't lower.
    Enum.each(targets, fn t ->
      case Map.get(t, "_type") do
        "Name" -> :ok
        "Subscript" -> :ok
        other ->
          raise UnsupportedNodeError,
            node_type: "Assign",
            hint:
              "multi-target Assign supports Name and Subscript targets; got `#{other}`",
            lineno: Map.get(node, "lineno"),
            col_offset: Map.get(node, "col_offset")
      end
    end)

    {value_ast, context} = convert(value, context)

    # Single-eval the value RHS when non-trivial so each target sees the
    # same evaluated value (matches Python: `a = b = expensive()` calls
    # `expensive` once).
    {bindings, value_ref, context} =
      if Trivial.trivial?(value) do
        {[], value_ast, context}
      else
        {temp_atom, context} = next_temp(context)
        temp_ref = {temp_atom, [], nil}
        {[{:=, [], [temp_ref, value_ast]}], temp_ref, context}
      end

    {assigns, context} =
      Enum.reduce(targets, {[], context}, fn target, {acc, ctx} ->
        {assign, ctx} = multi_assign_one(target, value_ref, node, ctx)
        {[assign | acc], ctx}
      end)

    block = bindings ++ Enum.reverse(assigns)
    {{:__block__, [], block}, context}
  end

  defp multi_assign_one(%{"_type" => "Name", "id" => id}, value_ref, _node, context) do
    rewritten = id |> Naming.rewrite() |> String.to_atom()
    context = bind_name(context, id)
    {{:=, [], [{rewritten, [], nil}, value_ref]}, context}
  end

  # `coll[idx] = value_ref` — rebind `coll` via py_setitem, mirroring
  # the single-target Subscript Assign path.
  defp multi_assign_one(
         %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => coll_id}, "slice" => slice},
         value_ref,
         _node,
         context
       ) do
    {slice_ast, context} = convert(slice, context)
    coll_atom = coll_id |> Naming.rewrite() |> String.to_atom()
    coll_ref = {coll_atom, [], nil}
    context = bind_name(context, coll_id)

    rhs = {:py_setitem, [], [coll_ref, slice_ast, value_ref]}
    {{:=, [], [coll_ref, rhs]}, context}
  end

  defp multi_assign_one(other, _value_ref, node, _context) do
    raise UnsupportedNodeError,
      node_type: "Assign",
      hint:
        "multi-target Assign target shape `#{Map.get(other, "_type")}` is not supported (only Name and Subscript-on-Name)",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp bind_tuple_names!(elts, context) do
    Enum.reduce(elts, context, fn
      %{"_type" => "Name", "id" => id}, ctx ->
        bind_name(ctx, id)

      other, _ctx ->
        raise UnsupportedNodeError,
          node_type: "Assign",
          hint:
            "tuple-Assign target requires all elements to be `Name` nodes; got `#{Map.get(other, "_type")}`"
    end)
  end

  # Mixed-target tuple-Assign emitter. Handles `a, b[i] = x, y`-shape
  # cases where at least one LHS is a depth-1 Subscript rooted at a
  # bare Name. RHS must be a Tuple literal with matching arity (the
  # general-RHS case — `a, b = some_call()` with subscript LHS — would
  # need destructure-then-index machinery; not implemented yet).
  defp emit_mixed_tuple_assign(elts, value, node, context) do
    rhs_elts =
      case value do
        %{"_type" => "Tuple", "elts" => rhs} when length(rhs) == length(elts) ->
          rhs

        _ ->
          raise UnsupportedNodeError,
            node_type: "Assign",
            hint:
              "tuple-Assign with a Subscript target requires a literal tuple RHS of matching arity",
            lineno: Map.get(node, "lineno"),
            col_offset: Map.get(node, "col_offset")
      end

    # Phase 1 — temp-bind every RHS value so writes can't clobber later
    # reads. The swap idiom (`t[i], t[i+1] = t[i+1], t[i]`) and the
    # mixed case (`y, xs[0] = xs[0], y` — where `y` is both LHS and
    # RHS) both need it. `maybe_temp_bind` skips trivial expressions,
    # but trivial-name RHS still gets clobbered when the same name is
    # ALSO a LHS target — so we always emit a temp here.
    {temps, bindings, context} =
      Enum.reduce(rhs_elts, {[], [], context}, fn rhs, {temps, binds, ctx} ->
        {ast, ctx} = convert(rhs, ctx)
        {temp_atom, ctx} = next_temp(ctx)
        temp_ref = {temp_atom, [], nil}
        binding = {:=, [], [temp_ref, ast]}
        {[temp_ref | temps], [binding | binds], ctx}
      end)

    temps = Enum.reverse(temps)
    bindings = Enum.reverse(bindings)

    # Phase 2 — apply each LHS in order using the matching temp.
    {assigns, context} =
      elts
      |> Enum.zip(temps)
      |> Enum.reduce({[], context}, fn {lhs, temp}, {acc, ctx} ->
        {ast, ctx} = apply_mixed_tuple_target(lhs, temp, ctx)
        {[ast | acc], ctx}
      end)

    assigns = Enum.reverse(assigns)
    {{:__block__, [], bindings ++ assigns}, context}
  end

  defp apply_mixed_tuple_target(%{"_type" => "Name", "id" => id}, temp, context) do
    context = bind_name(context, id)
    atom = id |> Naming.rewrite() |> String.to_atom()
    {{:=, [], [{atom, [], nil}, temp]}, context}
  end

  defp apply_mixed_tuple_target(
         %{
           "_type" => "Subscript",
           "value" => %{"_type" => "Name", "id" => coll_id} = collection,
           "slice" => slice
         },
         temp,
         context
       ) do
    {slice_ast, context} = convert(slice, context)
    {coll_ast, context} = convert(collection, context)
    setitem = {:py_setitem, [], [coll_ast, slice_ast, temp]}
    context = bind_name(context, coll_id)
    {{:=, [], [coll_ast, setitem]}, context}
  end

  defp apply_mixed_tuple_target(other, _temp, _context) do
    raise UnsupportedNodeError,
      node_type: "Assign",
      hint:
        "tuple-Assign element shape `#{Map.get(other, "_type")}` is not supported (only Name and depth-1 Subscript)"
  end

  # Walk a Subscript chain ending at a bare Name. Returns
  # `{:ok, root_id, slices_outermost_first}` or `:error` if the chain
  # bottoms out at something other than a Name (Attribute, Call, etc.).
  defp nested_subscript_chain(%{"_type" => "Subscript", "value" => v, "slice" => s}, acc) do
    case v do
      %{"_type" => "Name", "id" => id} -> {:ok, id, [s | acc]}
      %{"_type" => "Subscript"} = inner -> nested_subscript_chain(inner, [s | acc])
      _ -> :error
    end
  end

  defp target_root_type(%{"_type" => "Subscript", "value" => v}), do: target_root_type(v)
  defp target_root_type(%{"_type" => t}), do: t

  # `m[a][b]...[z] = v` → rebind `m` to a deeply-rebuilt copy.
  # Two-deep example: `m[a][b] = v` lowers to
  #   m = py_setitem(m, a, py_setitem(py_getitem(m, a), b, v))
  # The slices are temp-bound first to preserve Python's single-eval
  # semantics; the root is a bare Name so re-reading it is safe.
  defp emit_nested_subscript_assign(coll_id, slices, value, context) do
    {value_ast, context} = convert(value, context)
    {coll_ast, context} = convert(%{"_type" => "Name", "id" => coll_id}, context)

    {slice_refs, bindings, context} =
      Enum.reduce(slices, {[], [], context}, fn slice_node, {refs, binds, ctx} ->
        {ref, binding, ctx} = maybe_temp_bind(slice_node, ctx)
        binds = if binding, do: [binding | binds], else: binds
        {[ref | refs], binds, ctx}
      end)

    slice_refs = Enum.reverse(slice_refs)
    bindings = Enum.reverse(bindings)

    new_value = build_nested_setitem(coll_ast, slice_refs, value_ast)
    context = bind_name(context, coll_id)

    assign = {:=, [], [coll_ast, new_value]}

    case bindings do
      [] -> {assign, context}
      _ -> {{:__block__, [], bindings ++ [assign]}, context}
    end
  end

  defp build_nested_setitem(coll_ast, [last_slice], value_ast) do
    {:py_setitem, [], [coll_ast, last_slice, value_ast]}
  end

  defp build_nested_setitem(coll_ast, [s | rest], value_ast) do
    inner_get = {:py_getitem, [], [coll_ast, s]}
    inner_set = build_nested_setitem(inner_get, rest, value_ast)
    {:py_setitem, [], [coll_ast, s, inner_set]}
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

  # `zip(*xs)` is the only builtin that has a list-form lowering matching
  # Python's star-unpack semantics — `Enum.zip(xs)` already iterates a
  # list-of-iters in lockstep, same as `zip(*xs)`. For other in-scope
  # names (lambdas, demoted functions), emit `apply(fn_ref, args)`.
  # Top-level `defp`s — `Kernel.apply(__MODULE__, :name, args)`.
  defp emit_starred_call("zip", star_node, _node, context) do
    {arg_ast, context} = convert(star_node, context)
    {{{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [], [arg_ast]}, context}
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
    if Enum.all?(String.to_charlist(id), &(&1 == ?_)) do
      {{:_, [], nil}, [], context}
    else
      context = bind_name(context, id)
      atom = id |> Naming.rewrite() |> String.to_atom()
      {{atom, [], nil}, [id], context}
    end
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

  # Per-element helper for tuple-target recursion. Allows nested
  # tuples of Names — `for (a, b), c in pairs:` / `for (r, c), v in
  # bonuses.items():` etc. Each Name is treated like the single-Name
  # case (discard-rules, scope binding); each nested Tuple recurses.
  defp convert_loop_target_elt(%{"_type" => "Name", "id" => id}, context)
       when is_binary(id) and id != "" do
    if Enum.all?(String.to_charlist(id), &(&1 == ?_)) do
      {{:_, [], nil}, [], context}
    else
      context = bind_name(context, id)
      atom = id |> Naming.rewrite() |> String.to_atom()
      {{atom, [], nil}, [id], context}
    end
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

  # --- JoinedStr (f-string) part dispatch -------------------------------

  defp joined_str_part(%{"_type" => "Constant", "value" => v}, context) when is_binary(v),
    do: {v, context}

  defp joined_str_part(%{"_type" => "FormattedValue"} = node, context) do
    {value_ast, context} = convert(Map.fetch!(node, "value"), context)
    spec = extract_format_spec(Map.get(node, "format_spec"))

    case spec do
      :none ->
        {{:py_str, [], [value_ast]}, context}

      {:literal, text} ->
        # Dispatch to the runtime helper that interprets the spec at
        # runtime (Pylixir doesn't know `value`'s type statically).
        {{:py_format_value, [], [value_ast, text]}, context}

      :unsupported ->
        raise UnsupportedNodeError,
          node_type: "FormattedValue",
          hint:
            "f-string format specs with nested interpolation aren't supported — use a constant spec like `:.2f` or `\"{:.2f}\".format(x)`",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  defp joined_str_part(other, _context) do
    raise UnsupportedNodeError,
      node_type: "JoinedStr",
      hint:
        "unexpected JoinedStr child `#{Map.get(other, "_type")}` — expected Constant or FormattedValue"
  end

  # Format spec is itself a JoinedStr. If it's a single Constant string
  # (the common `:.2f` / `:02d` case), return its text; if it has
  # interpolations (`{width}`), fail.
  defp extract_format_spec(nil), do: :none
  defp extract_format_spec(%{"value" => nil}), do: :none

  defp extract_format_spec(%{"_type" => "JoinedStr", "values" => values}) do
    case values do
      [] -> :none
      [%{"_type" => "Constant", "value" => v}] when is_binary(v) -> {:literal, v}
      _ -> :unsupported
    end
  end

  defp extract_format_spec(m) when is_map(m) and map_size(m) == 0, do: :none
  defp extract_format_spec(_), do: :unsupported

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

  # `from <stdlib_mod> import <name> [as <alias>]` — emit a binding
  # for `<alias>` that mirrors what `import <mod>; <mod>.<name>` would
  # produce. Strategy depends on the kind of symbol:
  #
  #   * value-shaped (`sys.argv`, `sys.maxsize`): bind directly.
  #   * function-shaped (`bisect_left`, `gcd`, …): bind a lambda that
  #     forwards to the runtime helper — preserves the user's call
  #     shape (`gcd(a, b)`) without forcing the `mod.` prefix.
  #   * `stdin` (sys): bind a sentinel; `.read()` / `.readline()` on
  #     it dispatch via `attribute_methods` to the runtime helpers.
  defp stdlib_from_import_alias(mod, name, alias, context, node) do
    alias_atom = alias |> Naming.rewrite() |> String.to_atom()
    alias_ref = {alias_atom, [], nil}

    rhs =
      case import_alias_rhs(mod, name) do
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

  # `{:ok, ast}` returns the RHS to bind to the imported name.
  # Function-shaped imports use `&name/arity` captures so the user's
  # subsequent call shape works unchanged (and arity errors surface
  # at compile time, not as cryptic runtime crashes).
  defp import_alias_rhs("sys", "argv"),
    do: {:ok, {{:., [], [{:__aliases__, [], [:System]}, :argv]}, [], []}}

  defp import_alias_rhs("sys", "maxsize"), do: {:ok, 9_223_372_036_854_775_807}

  # `stdin` is bound to nil; bare attribute calls `stdin.read()` /
  # `stdin.readline()` are special-cased in `attribute_methods`.
  defp import_alias_rhs("sys", "stdin"), do: {:ok, nil}

  defp import_alias_rhs("sys", "setrecursionlimit"),
    do: {:ok, {:fn, [], [{:->, [], [[{:_n, [], nil}], nil]}]}}

  defp import_alias_rhs("sys", _), do: :error

  defp import_alias_rhs("math", name) do
    case math_name_arity(name) do
      {:ok, arity} -> {:ok, capture(name, arity)}
      :error -> :error
    end
  end

  defp import_alias_rhs("bisect", name) when name in ~w(bisect_left bisect_right bisect),
    do: {:ok, capture(bisect_target(name), 2)}

  defp import_alias_rhs("bisect", _), do: :error

  # Heapq: heappush/heappop/heapify all rebind their heap argument.
  # The rebind logic lives in the converter (see `emit_heapq_statement_rebind`
  # and the single_target_assign heappop clause) — bare captures like
  # `&py_heappush/2` wouldn't trigger that, so we bind a sentinel `nil`
  # instead and rely on `context.stdlib_aliases` to route bare-Name calls
  # back through the same rebind path used for `heapq.X(...)`.
  defp import_alias_rhs("heapq", n) when n in ~w(heappush heappop heapify), do: {:ok, nil}
  defp import_alias_rhs("heapq", _), do: :error

  defp import_alias_rhs("itertools", "combinations"), do: {:ok, capture(:py_combinations, 2)}
  # `permutations` is variadic in Python (1 or 2 args). Bind the 1-arg
  # form by default — calls like `permutations(xs, r)` will fail with
  # a clear arity error pointing to the import site.
  defp import_alias_rhs("itertools", "permutations"), do: {:ok, capture(:py_permutations, 1)}
  defp import_alias_rhs("itertools", _), do: :error

  defp import_alias_rhs(_mod, _name), do: :error

  defp math_name_arity(n) when n in ~w(sqrt floor ceil log log2 log10 sin cos tan asin acos atan exp isqrt factorial),
    do: {:ok, 1}

  defp math_name_arity(n) when n in ~w(pow atan2 gcd comb), do: {:ok, 2}
  defp math_name_arity(_), do: :error

  defp bisect_target("bisect_left"), do: :py_bisect_left
  defp bisect_target("bisect_right"), do: :py_bisect_right
  # Python: `bisect.bisect` is an alias for `bisect_right`.
  defp bisect_target("bisect"), do: :py_bisect_right

  defp capture(name, arity) when is_atom(name) and is_integer(arity) do
    # `&name/arity` — local capture; the helpers live in the same
    # module via the splice, so no remote-module prefix is needed.
    {:&, [], [{:/, [], [{name, [], nil}, arity]}]}
  end

  # Convenience for math: re-use the same Pylixir.Stdlib.Math lowering
  # so renames there propagate automatically. Math is special because
  # several names produce non-trivial AST (e.g. `floor` wraps with
  # `trunc`); for them we synthesise a fn over fresh params.
  defp capture(name_str, arity) when is_binary(name_str) do
    params = Enum.map(1..arity, fn i -> {String.to_atom("a#{i}"), [], nil} end)

    {:ok, body} =
      Pylixir.Stdlib.Math.call([name_str], params, %{}, %{"_type" => "Call", "lineno" => nil})

    {:fn, [], [{:->, [], [params, body]}]}
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

  defp reject_dict_unpack!(keys, dict_node) do
    if Enum.any?(keys, &is_nil/1) do
      raise UnsupportedNodeError,
        node_type: "Dict",
        hint: "dict-unpack (`{**d}`) is not supported",
        lineno: Map.get(dict_node, "lineno"),
        col_offset: Map.get(dict_node, "col_offset")
    end
  end

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
