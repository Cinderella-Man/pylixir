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

  alias Pylixir.AST.{BoolReturning, Trivial, Walk}
  alias Pylixir.{Builtins, Context, HelpersCodegen, LoopAnalysis, ModuleAnalysis, Naming, UnsupportedNodeError}

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

  # Minimal Call clause — supports `Name(args)` calls only. T28 will
  # generalize to `Attribute` calls, builtins, math, kwargs, local-scope
  # shadowing precedence with explicit `.(args)` for shadowed names.
  def convert(%{"_type" => "Call"} = node, context) do
    case node["func"] do
      %{"_type" => "Name", "id" => id} ->
        {arg_asts, context} = convert_each(Map.get(node, "args", []), context)
        {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)

        cond do
          id == context.recursive_self_binding ->
            self_ref = {:self, [], nil}
            atom = id |> Naming.rewrite() |> String.to_atom()
            _ = atom
            no_kwargs!(kwargs, id, node)
            {{{:., [], [self_ref]}, [], arg_asts ++ [self_ref]}, context}

          MapSet.member?(context.recursive_lambdas, id) ->
            atom = id |> Naming.rewrite() |> String.to_atom()
            ref = {atom, [], nil}
            no_kwargs!(kwargs, id, node)
            {{{:., [], [ref]}, [], arg_asts ++ [ref]}, context}

          name_in_scope?(context, id) ->
            atom = id |> Naming.rewrite() |> String.to_atom()
            ref = {atom, [], nil}
            no_kwargs!(kwargs, id, node)
            {{{:., [], [ref]}, [], arg_asts}, context}

          Builtins.supported?(id) ->
            {Builtins.emit(id, arg_asts, kwargs), context}

          true ->
            atom = id |> Naming.rewrite() |> String.to_atom()
            no_kwargs!(kwargs, id, node)
            {{atom, [], arg_asts}, context}
        end

      _ ->
        raise UnsupportedNodeError,
          node_type: "Call",
          hint:
            "only `Name(args)` call shapes are supported pre-T28; got `#{Map.get(node["func"], "_type")}`",
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

        {{:throw, [], [{:pylixir_return, value_ast}]}, context}
    end
  end

  def convert(%{"_type" => "FunctionDef"} = node, context) do
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

  def convert(%{"_type" => "ListComp", "elt" => elt, "generators" => generators}, context) do
    emit_comprehension(:list, elt, generators, context)
  end

  def convert(%{"_type" => "SetComp", "elt" => elt, "generators" => generators}, context) do
    emit_comprehension(:set, elt, generators, context)
  end

  def convert(%{"_type" => "GeneratorExp", "elt" => elt, "generators" => generators}, context) do
    emit_comprehension(:gen, elt, generators, context)
  end

  def convert(%{"_type" => "DictComp", "key" => key, "value" => value, "generators" => generators}, context) do
    emit_comprehension(:dict, {key, value}, generators, context)
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

  def convert(%{"_type" => "Lambda", "args" => args, "body" => body} = node, context) do
    validate_arguments!(args, node)
    reject_defaults!(args, "Lambda", node)
    {param_asts, context} = build_param_asts(args, context)
    param_names = arg_names(args)

    saved_scopes = context.scopes
    new_scope = MapSet.new(param_names)
    context = %{context | scopes: [new_scope | context.scopes]}

    {body_ast, context} = convert(body, context)

    context = %{context | scopes: saved_scopes}

    {{:fn, [], [{:->, [], [param_asts, body_ast]}]}, context}
  end

  def convert(%{"_type" => "While"} = node, context) do
    if Map.get(node, "orelse", []) != [] do
      raise UnsupportedNodeError,
        node_type: "While",
        hint: "while/else (Python's while-loop `else` clause) is not supported",
        lineno: Map.get(node, "lineno"),
        col_offset: Map.get(node, "col_offset")
    end

    emit_while(node, context)
  end

  def convert(%{"_type" => "For"} = node, context) do
    if Map.get(node, "orelse", []) != [] do
      raise UnsupportedNodeError,
        node_type: "For",
        hint: "for/else (Python's for-loop `else` clause) is not supported",
        lineno: Map.get(node, "lineno"),
        col_offset: Map.get(node, "col_offset")
    end

    emit_for(node, context)
  end

  def convert(%{"_type" => "Break"} = node, context) do
    case context.loop_break_payload do
      nil ->
        raise UnsupportedNodeError,
          node_type: "Break",
          hint: "`break` outside a loop is not supported (and is a SyntaxError in Python)",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      payload_ast ->
        {{:throw, [], [{:pylixir_break, payload_ast}]}, context}
    end
  end

  def convert(%{"_type" => "Continue"} = node, context) do
    case context.loop_break_payload do
      nil ->
        raise UnsupportedNodeError,
          node_type: "Continue",
          hint: "`continue` outside a loop is not supported (and is a SyntaxError in Python)",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      payload_ast ->
        {{:throw, [], [{:pylixir_continue, payload_ast}]}, context}
    end
  end

  # Minimal Expr clause: unwrap and convert the inner value. The full
  # plan T31 also drops the result unless it's a recognised mutation —
  # that distinction matters for statement-context method calls (T30)
  # but is a no-op for the T06–T15 features exercised here.
  def convert(%{"_type" => "Expr", "value" => value}, context), do: convert(value, context)

  def convert(%{"_type" => "If", "test" => test, "body" => body, "orelse" => orelse}, context) do
    case orelse do
      [] -> emit_if_only(test, body, context)
      [%{"_type" => "If"} = _elif | _] -> emit_cond_chain(test, body, orelse, context)
      _ -> emit_if_else(test, body, orelse, context)
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
    case ops do
      [single_op] ->
        [right_node] = comparators
        {left_ast, context} = convert(left, context)
        {right_ast, context} = convert(right_node, context)
        {compare_pair_ast(single_op, left_ast, right_ast), context}

      _ ->
        build_chained_compare(left, ops, comparators, context)
    end
  end

  def convert(%{"_type" => "List", "elts" => elts}, context) do
    reject_starred!(elts, "List")
    {asts, context} = convert_each(elts, context)
    {asts, context}
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

      true ->
        atom = id |> Naming.rewrite() |> String.to_atom()
        {{atom, [], nil}, context}
    end
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

  # --- Operator emission -------------------------------------------------

  defp unary_op_ast(%{"_type" => "UAdd"}, operand_ast, _node), do: operand_ast
  defp unary_op_ast(%{"_type" => "USub"}, operand_ast, _node), do: {:-, [], [operand_ast]}

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
  defp bin_op_ast(%{"_type" => "Sub"}, l, r, _node), do: {:-, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Mult"}, l, r, _node), do: {:py_mult, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Div"}, l, r, _node), do: {:/, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Pow"}, l, r, _node), do: {:py_pow, [], [l, r]}
  defp bin_op_ast(%{"_type" => "FloorDiv"}, l, r, _node), do: {:py_floor_div, [], [l, r]}
  defp bin_op_ast(%{"_type" => "Mod"}, l, r, _node), do: {:py_mod, [], [l, r]}
  defp bin_op_ast(%{"_type" => "LShift"}, l, r, _node), do: bitwise_call(:bsl, l, r)
  defp bin_op_ast(%{"_type" => "RShift"}, l, r, _node), do: bitwise_call(:bsr, l, r)
  defp bin_op_ast(%{"_type" => "BitOr"}, l, r, _node), do: bitwise_call(:bor, l, r)
  defp bin_op_ast(%{"_type" => "BitAnd"}, l, r, _node), do: bitwise_call(:band, l, r)
  defp bin_op_ast(%{"_type" => "BitXor"}, l, r, _node), do: bitwise_call(:bxor, l, r)

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

  defp single_target_assign(%{"_type" => "Name", "id" => id} = target, value, _node, context) do
    {value_ast, context} = convert(value, context)
    context = bind_name(context, id)
    {target_ast, context} = convert(target, context)
    {{:=, [], [target_ast, value_ast]}, context}
  end

  defp single_target_assign(%{"_type" => "Tuple", "elts" => elts} = target, value, _node, context) do
    reject_starred!(elts, "Tuple")
    {value_ast, context} = convert(value, context)
    context = bind_tuple_names!(elts, context)
    {target_ast, context} = convert(target, context)
    {{:=, [], [target_ast, value_ast]}, context}
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

  defp bind_name(context, name) when is_binary(name) do
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

  # --- Nested FunctionDef emission (T21) --------------------------------

  defp emit_nested_function_def(node, context) do
    %{"name" => name, "args" => args, "body" => body} = node

    if Map.get(node, "decorator_list", []) != [] do
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

    {body_asts, context} = convert_each(body, context)

    context = %{
      context
      | scopes: saved_scopes,
        recursive_self_binding: saved_self,
        return_mode: saved_return_mode
    }

    body_block =
      case body_asts do
        [] -> nil
        _ -> body_to_block(body_asts)
      end

    body_block = maybe_wrap_return_catch(body_block, return_mode)

    fn_params = if recursive?, do: param_asts ++ [{:self, [], nil}], else: param_asts
    fn_ast = {:fn, [], [{:->, [], [fn_params, body_block]}]}

    name_atom = name |> Naming.rewrite() |> String.to_atom()

    context = bind_name(context, name)

    context =
      if recursive? do
        %{context | recursive_lambdas: MapSet.put(context.recursive_lambdas, name)}
      else
        context
      end

    {{:=, [], [{name_atom, [], nil}, fn_ast]}, context}
  end

  # --- Comprehensions (T24 + T24b) --------------------------------------

  defp emit_comprehension(kind, elt_node, generators, context) do
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
    {iter_ast, context} = convert(iter, context)
    saved_scopes = context.scopes
    {target_ast, _, context} = convert_loop_target(target, context)
    {filtered_iter, context} = apply_filter(iter_ast, target_ast, ifs, context)
    {leaf, context} = comp_leaf(elt_node, kind, context)

    pipeline =
      {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [],
       [filtered_iter, {:fn, [], [{:->, [], [[target_ast], leaf]}]}]}

    context = %{context | scopes: saved_scopes}
    {pipeline, context}
  end

  # Multiple generators: flat_map of the rest.
  defp build_comp([%{"target" => target, "iter" => iter, "ifs" => ifs} | rest], elt_node, kind, context) do
    {iter_ast, context} = convert(iter, context)
    saved_scopes = context.scopes
    {target_ast, _, context} = convert_loop_target(target, context)
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
        {test_ast, ctx} = convert_test(cond_node, ctx)
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
    convert(elt_node, context)
  end

  defp comp_leaf({key_node, value_node}, :dict, context) do
    {k_ast, context} = convert(key_node, context)
    {v_ast, context} = convert(value_node, context)
    {{k_ast, v_ast}, context}
  end

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

  # --- FunctionDef emission (T19) ---------------------------------------

  defp emit_function_def(node, context) do
    %{"name" => py_name, "args" => args, "body" => body} = node

    if Map.get(node, "decorator_list", []) != [] do
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

    new_scope = MapSet.new(param_names)

    context = %{
      context
      | scopes: [new_scope | context.scopes],
        def_position: :nested_fn,
        return_mode: return_mode
    }

    {body_asts, context} = convert_each(body, context)

    context = %{
      context
      | scopes: saved_scopes,
        def_position: saved_def_position,
        return_mode: saved_return_mode
    }

    body_block =
      case body_asts do
        [] -> nil
        _ -> body_to_block(body_asts)
      end

    body_block = maybe_wrap_return_catch(body_block, return_mode)

    fn_name_atom = py_name |> Naming.rewrite() |> String.to_atom()
    defp_ast = {:defp, [], [{fn_name_atom, [], param_asts}, [do: body_block]]}
    {defp_ast, context}
  end

  # Conservative wrap rule (Q19): wrap iff 2+ Returns, OR exactly 1 Return
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

    catch_clause =
      {:->, [], [[:throw, {:pylixir_return, val_ref}], val_ref]}

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
          {default_ast, ctx} = convert(default_node, ctx)
          {[{:\\, [], [arg_ref, default_ast]} | acc], ctx}
        else
          {[arg_ref | acc], ctx}
        end
      end)

    {Enum.reverse(asts), context}
  end

  # --- While-loop emission (T18) ----------------------------------------

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
      |> Enum.filter(&var_bound?(pre_loop_context, &1))
      |> Enum.sort()

    {payload_ast, _refs} = build_acc_refs(threaded)
    flow = loop_flow(body)

    saved_payload = context.loop_break_payload
    context = %{context | loop_break_payload: payload_ast}
    {test_ast, context} = convert_test(test, context)
    {body_asts, context} = convert_each(body, context)
    context = %{context | loop_break_payload: saved_payload}

    threaded_refs =
      Enum.map(threaded, fn v -> {v |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    read_only_refs =
      Enum.map(read_only, fn v -> {v |> Naming.rewrite() |> String.to_atom(), [], nil} end)

    param_refs = threaded_refs ++ read_only_refs
    state_value = state_value_ast(threaded, threaded_refs)
    initial_args = Enum.map(threaded ++ read_only, &initial_ref(&1, pre_loop_context))

    recurse_call = {fn_name, [], param_refs}
    body_with_recurse = body_to_block(body_asts ++ [recurse_call])
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
      Enum.reduce(threaded, context, fn v, ctx -> bind_name(ctx, v) end)

    final_ast =
      case threaded do
        [] -> wrapped_call
        _ -> {:=, [], [payload_ast, wrapped_call]}
      end

    {final_ast, context}
  end

  defp state_value_ast([], _refs), do: :ok
  defp state_value_ast([_single], [ref]), do: ref
  defp state_value_ast(_, refs), do: tuple_pattern(refs)

  # While-specific continue: catch arm calls the recursive helper with the
  # captured state (post-body-so-far values), so continue advances rather
  # than spinning with pre-iteration values.
  defp maybe_continue_while(body_block, _payload_ast, _recurse_call, false), do: body_block

  defp maybe_continue_while(body_block, payload_ast, recurse_call, true) do
    catch_clause =
      {:->, [], [[:throw, {:pylixir_continue, payload_ast}], recurse_call]}

    {:try, [], [[do: body_block, catch: [catch_clause]]]}
  end

  # --- For-loop emission (T16b + T17) -----------------------------------

  defp emit_for(%{"target" => target, "iter" => iter, "body" => body}, context) do
    pre_loop_context = context

    {iter_ast, context} = convert(iter, context)
    {target_ast, target_names, context} = convert_loop_target(target, context)

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
    {body_asts, context} = convert_each(body, context)
    context = %{context | loop_break_payload: saved}

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
      node |> Map.delete("_type") |> Enum.reduce(acc, fn {_k, v}, a -> same_loop_walk(v, a, fun) end)
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

    {tuple_pattern(refs), refs}
  end

  defp emit_for_each(iter_ast, target_ast, body_asts, {has_break?, has_continue?}, context) do
    body_block = body_to_block(body_asts)
    body_with_continue = maybe_continue_each(body_block, has_continue?)
    fn_ast = {:fn, [], [{:->, [], [[target_ast], body_with_continue]}]}
    each_call = {{:., [], [{:__aliases__, [], [:Enum]}, :each]}, [], [iter_ast, fn_ast]}
    wrapped = maybe_break_each(each_call, has_break?)
    {wrapped, context}
  end

  defp maybe_continue_each(body_block, false), do: body_block

  defp maybe_continue_each(body_block, true) do
    catch_clause =
      {:->, [], [[:throw, {:pylixir_continue, {:_, [], nil}}], :ok]}

    {:try, [], [[do: body_block, catch: [catch_clause]]]}
  end

  defp maybe_break_each(call, false), do: call

  defp maybe_break_each(call, true) do
    catch_clause =
      {:->, [],
       [[:throw, {:pylixir_break, {:_, [], nil}}], :ok]}

    {:try, [], [[do: call, catch: [catch_clause]]]}
  end

  defp emit_for_reduce_single(iter_ast, target_ast, var, body_asts, pre_ctx, flow, context) do
    acc_ref = {var |> Naming.rewrite() |> String.to_atom(), [], nil}
    initial = initial_ref(var, pre_ctx)

    inner_body = body_to_block(body_asts ++ [acc_ref])
    inner_body = maybe_continue_iter(inner_body, acc_ref, elem(flow, 1))

    fn_ast = {:fn, [], [{:->, [], [[target_ast, acc_ref], inner_body]}]}

    reduce =
      {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [iter_ast, initial, fn_ast]}

    rhs = maybe_break_reduce(reduce, acc_ref, elem(flow, 0))
    context = bind_name(context, var)
    {{:=, [], [acc_ref, rhs]}, context}
  end

  defp emit_for_reduce_tuple(iter_ast, target_ast, vars, acc_refs, body_asts, pre_ctx, flow, context) do
    acc_pattern = tuple_pattern(acc_refs)
    initial = tuple_pattern(Enum.map(vars, &initial_ref(&1, pre_ctx)))

    inner_body = body_to_block(body_asts ++ [acc_pattern])
    inner_body = maybe_continue_iter(inner_body, acc_pattern, elem(flow, 1))

    fn_ast = {:fn, [], [{:->, [], [[target_ast, acc_pattern], inner_body]}]}

    reduce =
      {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [iter_ast, initial, fn_ast]}

    rhs = maybe_break_reduce(reduce, acc_pattern, elem(flow, 0))
    context = Enum.reduce(vars, context, &bind_name(&2, &1))
    {{:=, [], [acc_pattern, rhs]}, context}
  end

  defp maybe_continue_iter(body_block, _acc, false), do: body_block

  defp maybe_continue_iter(body_block, acc_ast, true) do
    # Captured pattern binds whatever Continue threw; the catch arm
    # returns it as the new iteration accumulator.
    catch_clause =
      {:->, [], [[:throw, {:pylixir_continue, acc_ast}], acc_ast]}

    {:try, [], [[do: body_block, catch: [catch_clause]]]}
  end

  defp maybe_break_reduce(reduce_call, _acc_pattern, false), do: reduce_call

  defp maybe_break_reduce(reduce_call, acc_pattern, true) do
    catch_clause =
      {:->, [], [[:throw, {:pylixir_break, acc_pattern}], acc_pattern]}

    {:try, [], [[do: reduce_call, catch: [catch_clause]]]}
  end

  defp initial_ref(var, context) do
    if var_bound?(context, var) do
      {var |> Naming.rewrite() |> String.to_atom(), [], nil}
    else
      nil
    end
  end

  defp var_bound?(context, var) do
    Enum.any?(context.scopes, &MapSet.member?(&1, var))
  end

  defp name_in_scope?(context, name) do
    Enum.any?(context.scopes, &MapSet.member?(&1, name))
  end

  defp convert_keywords([], context), do: {%{}, context}

  defp convert_keywords(keywords, context) do
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

  defp tuple_pattern([a, b]), do: {a, b}
  defp tuple_pattern(refs), do: {:{}, [], refs}

  defp convert_loop_target(%{"_type" => "Name", "id" => id}, context) do
    context = bind_name(context, id)
    atom = id |> Naming.rewrite() |> String.to_atom()
    {{atom, [], nil}, [id], context}
  end

  defp convert_loop_target(%{"_type" => "Tuple", "elts" => elts}, context) do
    reject_starred!(elts, "Tuple")

    {refs, names, context} =
      Enum.reduce(elts, {[], [], context}, fn
        %{"_type" => "Name", "id" => id}, {refs, names, ctx} ->
          ctx = bind_name(ctx, id)
          atom = id |> Naming.rewrite() |> String.to_atom()
          {[{atom, [], nil} | refs], [id | names], ctx}

        other, _acc ->
          raise UnsupportedNodeError,
            node_type: "For",
            hint:
              "for-loop tuple-target element must be a Name; got `#{Map.get(other, "_type")}`"
      end)

    {tuple_pattern(Enum.reverse(refs)), Enum.reverse(names), context}
  end

  defp convert_loop_target(target, _context) do
    raise UnsupportedNodeError,
      node_type: "For",
      hint:
        "for-loop target shape `#{Map.get(target, "_type")}` is not supported (use a Name or Tuple of Names)"
  end

  # --- If / IfExp emission ----------------------------------------------

  defp emit_if_only(test, body, context) do
    {test_ast, context} = convert_test(test, context)
    {body_block, context} = convert_body_block(body, context)
    {{:if, [], [test_ast, [do: body_block]]}, context}
  end

  defp emit_if_else(test, body, orelse, context) do
    {test_ast, context} = convert_test(test, context)
    {body_block, context} = convert_body_block(body, context)
    {else_block, context} = convert_body_block(orelse, context)
    {{:if, [], [test_ast, [do: body_block, else: else_block]]}, context}
  end

  defp emit_cond_chain(test, body, orelse, context) do
    {clauses, terminal_else, context} = collect_cond_chain(test, body, orelse, context, [])

    arrow_clauses =
      Enum.map(Enum.reverse(clauses), fn {t, b} -> {:->, [], [[t], b]} end)

    fallthrough_body = terminal_else || nil
    all_clauses = arrow_clauses ++ [{:->, [], [[true], fallthrough_body]}]

    {{:cond, [], [[do: all_clauses]]}, context}
  end

  defp collect_cond_chain(test, body, orelse, context, acc) do
    {test_ast, context} = convert_test(test, context)
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

  defp convert_test(test_node, context) do
    {test_ast, context} = convert(test_node, context)

    wrapped =
      if BoolReturning.bool_returning?(test_node) do
        test_ast
      else
        {:truthy?, [], [test_ast]}
      end

    {wrapped, context}
  end

  defp convert_body_block(stmts, context) do
    {asts, context} = convert_each(stmts, context)
    {body_to_block(asts), context}
  end

  defp body_to_block([]), do: nil
  defp body_to_block([single]), do: single
  defp body_to_block(many), do: {:__block__, [], many}

  defp maybe_temp_bind(node, context) do
    {ast, context} = convert(node, context)

    if Trivial.trivial?(node) do
      {ast, nil, context}
    else
      {temp_atom, context} = next_temp(context)
      temp_ref = {temp_atom, [], nil}
      {temp_ref, {:=, [], [temp_ref, ast]}, context}
    end
  end

  # --- Chained Compare with single-evaluation temps ---------------------

  defp build_chained_compare(left, ops, comparators, context) do
    {left_ast, context} = convert(left, context)
    {middles, last} = Enum.split(comparators, length(comparators) - 1)

    {middle_refs, temp_bindings, context} = build_middle_refs(middles, context)

    {last_ast, context} = convert(hd(last), context)

    operand_asts = [left_ast | middle_refs] ++ [last_ast]
    pairs = build_compare_pairs(operand_asts, ops)
    [first_pair | rest_pairs] = pairs
    chain = Enum.reduce(rest_pairs, first_pair, fn p, acc -> {:&&, [], [acc, p]} end)

    result =
      case temp_bindings do
        [] -> chain
        _ -> {:__block__, [], temp_bindings ++ [chain]}
      end

    {result, context}
  end

  defp build_middle_refs(middles, context) do
    {refs, bindings, context} =
      Enum.reduce(middles, {[], [], context}, fn cmp_node, {refs, bindings, ctx} ->
        {ast, ctx} = convert(cmp_node, ctx)

        if Trivial.trivial?(cmp_node) do
          {[ast | refs], bindings, ctx}
        else
          {temp_atom, ctx} = next_temp(ctx)
          temp_ref = {temp_atom, [], nil}
          binding = {:=, [], [temp_ref, ast]}
          {[temp_ref | refs], [binding | bindings], ctx}
        end
      end)

    {Enum.reverse(refs), Enum.reverse(bindings), context}
  end

  defp build_compare_pairs(operands, ops) do
    pairs = Enum.zip(operands, tl(operands))

    Enum.zip(pairs, ops)
    |> Enum.map(fn {{l, r}, op} -> compare_pair_ast(op, l, r) end)
  end

  defp next_temp(context) do
    n = context.temp_counter
    atom = String.to_atom("py_tmp_#{n}")
    {atom, %{context | temp_counter: n + 1}}
  end

  defp compare_pair_ast(%{"_type" => "Eq"}, l, r), do: {:==, [], [l, r]}
  defp compare_pair_ast(%{"_type" => "NotEq"}, l, r), do: {:!=, [], [l, r]}
  defp compare_pair_ast(%{"_type" => "Lt"}, l, r), do: {:<, [], [l, r]}
  defp compare_pair_ast(%{"_type" => "LtE"}, l, r), do: {:<=, [], [l, r]}
  defp compare_pair_ast(%{"_type" => "Gt"}, l, r), do: {:>, [], [l, r]}
  defp compare_pair_ast(%{"_type" => "GtE"}, l, r), do: {:>=, [], [l, r]}
  defp compare_pair_ast(%{"_type" => "Is"}, l, r), do: {:==, [], [l, r]}
  defp compare_pair_ast(%{"_type" => "IsNot"}, l, r), do: {:!=, [], [l, r]}
  defp compare_pair_ast(%{"_type" => "In"}, l, r), do: {:py_in, [], [l, r]}

  defp compare_pair_ast(%{"_type" => "NotIn"}, l, r),
    do: {:!, [], [{:py_in, [], [l, r]}]}

  # --- Literal-container rejections --------------------------------------

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

  defp convert_optional(nil, context), do: {nil, context}
  defp convert_optional(node, context), do: convert(node, context)

  defp convert_each(nodes, context) do
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
    {:def, [], [{:py_main, [], nil}, [do: single]]}
  end

  defp py_main_def(many) do
    {:def, [], [{:py_main, [], nil}, [do: {:__block__, [], many}]]}
  end
end
