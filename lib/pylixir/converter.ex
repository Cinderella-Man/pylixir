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
  alias Pylixir.{Context, HelpersCodegen, ModuleAnalysis, Naming, UnsupportedNodeError}

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
    {stmt_asts, context} = convert_each(analysis.runtime_statements, context)

    helpers = HelpersCodegen.helpers_ast()
    body_block = helpers ++ attr_asts ++ fn_asts ++ [py_main_def(stmt_asts)]

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
