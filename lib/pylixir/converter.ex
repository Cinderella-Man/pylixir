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

    # Runtime statements live inside py_main; nested FunctionDefs there
    # are inside control flow (or `If`/`For`/etc.) and must raise per T19.
    context = %{context | def_position: :other}
    {stmt_asts, context} = convert_each(analysis.runtime_statements, context)
    context = %{context | def_position: :module_top}

    helpers = HelpersCodegen.helpers_ast()

    body_block =
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
  # module name the registry doesn't know about.
  def convert(%{"_type" => "Import", "names" => names}, context) do
    case Enum.find(names, fn %{"name" => n} -> not Stdlib.supported?(n) end) do
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
  def convert(%{"_type" => "ImportFrom", "module" => "math", "names" => names}, context) do
    {stmts, context} =
      Enum.reduce(names, {[], context}, fn %{"name" => n}, {acc, ctx} ->
        {stmt, ctx} = math_import_alias(n, ctx)
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

  # Expr: drop the result unless the inner value is a recognised
  # mutation method, in which case T30 rewrites it to a target
  # reassignment. Also handles the heapq statement idiom
  # `heapq.heappush(heap, item)` / `heapq.heapify(heap)` — both
  # mutate `heap` in Python and need a rebind in Pylixir.
  def convert(%{"_type" => "Expr", "value" => value}, context) do
    case heapq_statement_mutation(value) do
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
      [single] -> single_target_assign(single, value, node, context)
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
  defp heapq_statement_mutation(%{
         "_type" => "Call",
         "func" => %{
           "_type" => "Attribute",
           "value" => %{"_type" => "Name", "id" => "heapq"},
           "attr" => method
         },
         "args" => [%{"_type" => "Name", "id" => heap_name} | rest]
       })
       when method in ["heappush", "heapify"] do
    {:ok, heap_name, method, rest}
  end

  defp heapq_statement_mutation(_), do: :none

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

  defp single_target_assign(%{"_type" => "Tuple", "elts" => elts} = target, value, node, context) do
    reject_starred!(elts, "Tuple")

    if Enum.all?(elts, &match?(%{"_type" => "Name"}, &1)) do
      # Pure tuple-of-Names destructure (e.g. `a, b = (1, 2)`).
      {value_ast, context} = convert(value, context)
      context = bind_tuple_names!(elts, context)
      {target_ast, context} = convert(target, context)
      {{:=, [], [target_ast, value_ast]}, context}
    else
      # Mixed Name/Subscript targets (e.g. the swap idiom
      # `t[i], t[i+1] = t[i+1], t[i]`). Can't use Elixir's
      # destructure-match because Subscript isn't a valid pattern.
      # Strategy: temp-bind every RHS value once (single-eval), then
      # apply each LHS in order — Names become normal binds, Subscripts
      # become py_setitem rebinds of the root.
      emit_mixed_tuple_assign(elts, value, node, context)
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
    {value_ast, context} = convert(value, context)
    {slice_ast, context} = convert(slice, context)
    {coll_ast, context} = convert(collection, context)
    setitem = {:py_setitem, [], [coll_ast, slice_ast, value_ast]}
    context = bind_name(context, coll_id)
    {{:=, [], [coll_ast, setitem]}, context}
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

  defp multi_target_assign(targets, value, node, context) do
    name_ids = Enum.map(targets, &name_id_or_raise!(&1, node))
    {value_ast, context} = convert(value, context)

    {bindings, value_ref, context} =
      if Trivial.trivial?(value) do
        {[], value_ast, context}
      else
        {temp_atom, context} = next_temp(context)
        temp_ref = {temp_atom, [], nil}
        {[{:=, [], [temp_ref, value_ast]}], temp_ref, context}
      end

    {assigns, context} =
      Enum.reduce(name_ids, {[], context}, fn id, {acc, ctx} ->
        ctx = bind_name(ctx, id)
        rewritten = id |> Naming.rewrite() |> String.to_atom()
        assign = {:=, [], [{rewritten, [], nil}, value_ref]}
        {[assign | acc], ctx}
      end)

    block = bindings ++ Enum.reverse(assigns)
    {{:__block__, [], block}, context}
  end

  defp name_id_or_raise!(%{"_type" => "Name", "id" => id}, _node), do: id

  defp name_id_or_raise!(other, node) do
    raise UnsupportedNodeError,
      node_type: "Assign",
      hint:
        "multi-target Assign requires all targets to be `Name` nodes; got `#{Map.get(other, "_type")}`",
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
    {arg_asts, context} = convert_each(Map.get(node, "args", []), context)
    {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)

    cond do
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
    if Map.get(node, "format_spec") not in [nil, %{"value" => nil}, %{}],
      do:
        raise(UnsupportedNodeError,
          node_type: "FormattedValue",
          hint:
            "f-string format specs (`f\"{x:.2f}\"`) aren't supported yet — use `\"{:.2f}\".format(x)` instead",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
        )

    {value_ast, context} = convert(Map.fetch!(node, "value"), context)
    {{:py_str, [], [value_ast]}, context}
  end

  defp joined_str_part(other, _context) do
    raise UnsupportedNodeError,
      node_type: "JoinedStr",
      hint:
        "unexpected JoinedStr child `#{Map.get(other, "_type")}` — expected Constant or FormattedValue"
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

  # `from math import <name>` — emit `<name> = fn ... -> <math AST> end`.
  # Routes through `Pylixir.Stdlib.Math.call/4`'s existing clauses so
  # there's no duplication of the lowering.
  defp math_import_alias(name, context) do
    params =
      cond do
        name in ~w(sqrt floor ceil log log2 log10 sin cos tan asin acos atan exp isqrt) ->
          [{:x, [], nil}]

        name in ~w(pow atan2 gcd) ->
          [{:a, [], nil}, {:b, [], nil}]

        true ->
          raise UnsupportedNodeError,
            node_type: "ImportFrom",
            hint:
              "`from math import #{name}` is not supported (allowed: " <>
                "sqrt floor ceil log log2 log10 sin cos tan asin acos atan exp " <>
                "isqrt pow atan2 gcd)"
      end

    {:ok, body} =
      Pylixir.Stdlib.Math.call([name], params, %{}, %{"_type" => "Call", "lineno" => nil})

    fn_ast = {:fn, [], [{:->, [], [params, body]}]}
    name_atom = name |> Naming.rewrite() |> String.to_atom()
    context = bind_name(context, name)
    {{:=, [], [{name_atom, [], nil}, fn_ast]}, context}
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
    {value_ast, context} = convert(value_node, context)
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
