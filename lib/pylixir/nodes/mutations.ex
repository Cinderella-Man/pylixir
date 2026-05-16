defmodule Pylixir.Nodes.Mutations do
  @moduledoc """
  Statement-context translations for Python's in-place mutation methods —
  `xs.append(x)`, `d.update(other)`, `xs.sort()`, etc. (T30).

  Pylixir treats Python's mutable containers as Elixir immutables: the
  statement `xs.append(x)` lowers to `xs = xs ++ [x]` rather than a true
  in-place mutation. The classifier `detect/1` recognises two target
  shapes:

    * `xs.method(args)`      — bare Name target; `{:name, …}` tuple.
    * `coll[i].method(args)` — depth-1 Subscript target rooted at a
      bare Name; `{:subscript, …}` tuple. Caller dispatches to
      `emit/6` or `emit_subscript/7` accordingly.

  The Subscript form rebinds the root: `coll[i].append(x)` lowers to
  `coll = py_setitem(coll, i, py_getitem(coll, i) ++ [x])`. The slice
  is temp-bound when non-trivial to preserve single-eval semantics.
  Deeper chains (`m[i][j].method(args)`) are not yet supported.
  """

  alias Pylixir.{Converter, Naming, UnsupportedNodeError}

  @methods ~w(append sort reverse insert extend remove clear pop add discard update)

  @doc """
  Classify a Python `Expr.value` node. Returns `:none`, a `{:name, …}`
  tuple for the bare-Name case, or a `{:subscript, …}` tuple for the
  depth-1 subscript case.
  """
  @spec detect(map()) ::
          :none
          | {:name, String.t(), String.t(), [map()], [map()], map()}
          | {:subscript, String.t(), map(), String.t(), [map()], [map()], map()}
  def detect(
        %{
          "_type" => "Call",
          "func" => %{
            "_type" => "Attribute",
            "value" => %{"_type" => "Name", "id" => name},
            "attr" => attr
          },
          "args" => args
        } = source
      )
      when attr != nil do
    if attr in @methods do
      kwargs_raw = Map.get(source, "keywords", [])
      {:name, name, attr, args, kwargs_raw, source}
    else
      :none
    end
  end

  def detect(
        %{
          "_type" => "Call",
          "func" => %{
            "_type" => "Attribute",
            "value" => %{
              "_type" => "Subscript",
              "value" => %{"_type" => "Name", "id" => name},
              "slice" => slice
            },
            "attr" => attr
          },
          "args" => args
        } = source
      )
      when attr != nil do
    if attr in @methods do
      kwargs_raw = Map.get(source, "keywords", [])
      {:subscript, name, slice, attr, args, kwargs_raw, source}
    else
      :none
    end
  end

  def detect(_), do: :none

  @spec emit(String.t(), String.t(), [map()], [map()], map(), Pylixir.Context.t()) ::
          {Macro.t(), Pylixir.Context.t()}
  def emit(target_name, method, args, kwargs_raw, source, context) do
    {arg_asts, context} = Converter.convert_each(args, context)
    {kwargs, context} = Converter.convert_keywords(kwargs_raw, context)

    target_atom = target_name |> Naming.rewrite() |> String.to_atom()
    target_ast = {target_atom, [], nil}
    new_value = mutation_rhs(method, target_ast, arg_asts, kwargs, source)

    context = Converter.bind_name(context, target_name)
    {{:=, [], [target_ast, new_value]}, context}
  end

  # `coll[i].method(args)` — rebind `coll` to a copy where the i-th
  # element has been mutated. The slice is `maybe_temp_bind`'d so
  # single-eval semantics hold for non-trivial slices (the slice
  # appears twice in the output: once in `py_getitem`, once in
  # `py_setitem`).
  @spec emit_subscript(String.t(), map(), String.t(), [map()], [map()], map(), Pylixir.Context.t()) ::
          {Macro.t(), Pylixir.Context.t()}
  def emit_subscript(coll_name, slice_node, method, args, kwargs_raw, source, context) do
    {arg_asts, context} = Converter.convert_each(args, context)
    {kwargs, context} = Converter.convert_keywords(kwargs_raw, context)
    {slice_ref, slice_binding, context} = Converter.maybe_temp_bind(slice_node, context)

    coll_atom = coll_name |> Naming.rewrite() |> String.to_atom()
    coll_ref = {coll_atom, [], nil}
    inner_get = {:py_getitem, [], [coll_ref, slice_ref]}
    new_inner = mutation_rhs(method, inner_get, arg_asts, kwargs, source)
    setitem = {:py_setitem, [], [coll_ref, slice_ref, new_inner]}
    assign = {:=, [], [coll_ref, setitem]}

    context = Converter.bind_name(context, coll_name)

    ast =
      case slice_binding do
        nil -> assign
        b -> {:__block__, [], [b, assign]}
      end

    {ast, context}
  end

  defp mutation_rhs("append", target, [x], _kw, _node),
    do: {:++, [], [target, [x]]}

  defp mutation_rhs("sort", target, [], kw, _node) do
    base =
      case Map.get(kw, "key") do
        nil -> {{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [target]}
        f -> {{:., [], [{:__aliases__, [], [:Enum]}, :sort_by]}, [], [target, f]}
      end

    case Map.get(kw, "reverse") do
      nil -> base
      true -> {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [base]}
      _ -> base
    end
  end

  defp mutation_rhs("reverse", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [target]}

  defp mutation_rhs("insert", target, [i, x], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:List]}, :insert_at]}, [], [target, i, x]}

  defp mutation_rhs("extend", target, [other], _kw, _node),
    do: {:++, [], [target, other]}

  defp mutation_rhs("remove", target, [x], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:List]}, :delete]}, [], [target, x]}

  defp mutation_rhs("clear", target, [], _kw, _node) do
    # Heuristic at codegen time — emit a runtime branch.
    is_struct_call = {:is_struct, [], [target, {:__aliases__, [], [:MapSet]}]}
    new_mapset = {{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], []}
    is_list_call = {:is_list, [], [target]}
    is_map_call = {:is_map, [], [target]}

    {:cond, [],
     [
       [
         do: [
           {:->, [], [[is_struct_call], new_mapset]},
           {:->, [], [[is_list_call], []]},
           {:->, [], [[is_map_call], {:%{}, [], []}]},
           {:->, [], [[true], nil]}
         ]
       ]
     ]}
  end

  defp mutation_rhs("pop", target, [], _kw, _node) do
    # Statement-context pop() — discard the popped element, keep the list.
    {{:., [], [{:__aliases__, [], [:Kernel]}, :elem]}, [],
     [{{:., [], [{:__aliases__, [], [:List]}, :pop_at]}, [], [target, -1]}, 1]}
  end

  defp mutation_rhs("pop", target, [i], _kw, _node) do
    {{:., [], [{:__aliases__, [], [:Kernel]}, :elem]}, [],
     [{{:., [], [{:__aliases__, [], [:List]}, :pop_at]}, [], [target, i]}, 1]}
  end

  defp mutation_rhs("add", target, [x], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:MapSet]}, :put]}, [], [target, x]}

  defp mutation_rhs("discard", target, [x], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:MapSet]}, :delete]}, [], [target, x]}

  defp mutation_rhs("update", target, [other], _kw, _node) do
    # dict.update(other) → Map.merge; MapSet.update(other) → MapSet.union.
    # Branch at runtime.
    {:cond, [],
     [
       [
         do: [
           {:->, [],
            [
              [{:is_struct, [], [target, {:__aliases__, [], [:MapSet]}]}],
              {{:., [], [{:__aliases__, [], [:MapSet]}, :union]}, [], [target, other]}
            ]},
           {:->, [],
            [[true], {{:., [], [{:__aliases__, [], [:Map]}, :merge]}, [], [target, other]}]}
         ]
       ]
     ]}
  end

  defp mutation_rhs(method, _target, args, _kw, node) do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint: "mutation method `.#{method}(#{length(args)} args)` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end
end
