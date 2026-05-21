defmodule Pylixir.TypeInfer do
  @moduledoc """
  Static type inference for Python AST nodes — drives monomorphic
  specialization at conversion time. See
  `docs/02_type-inference-monomorphization.md` for the full design.

  State is threaded through `Pylixir.Context` via the `:types`,
  `:type_stack`, `:fn_signatures`, and `:heap_types` fields. The
  fallback at every site is `:any`, which produces no specialization —
  this module is purely additive on top of the polymorphic helpers.
  """

  alias Pylixir.Context

  @type t ::
          :any
          | :bottom
          | {:int}
          | {:int_lit_nonneg}
          | {:float}
          | {:bool}
          | {:str}
          | {:none}
          | {:list, t()}
          | {:py_alist, t()}
          | {:py_pvec, t()}
          | {:tuple, [t()] | :any_arity}
          | {:dict, t(), t()}
          | {:set}
          | {:fn, [t()], t()}
          | {:union, MapSet.t(t())}

  # ---------------------------------------------------------------------
  # Predicates — concrete tags only. Unions and :any fall through.
  # `is_int?` matches the {:int_lit_nonneg} refinement subtype too.
  # ---------------------------------------------------------------------

  @spec is_int?(t()) :: boolean()
  def is_int?({:int}), do: true
  def is_int?({:int_lit_nonneg}), do: true
  def is_int?(_), do: false

  @spec is_str?(t()) :: boolean()
  def is_str?({:str}), do: true
  def is_str?(_), do: false

  @spec is_list?(t()) :: boolean()
  def is_list?({:list, _}), do: true
  # `{:py_alist, _}` is deliberately NOT treated as a list here —
  # `coerce_iter/2` skips its `py_iter_to_list` wrap when the type
  # is_list? is true, but an alist DOES need the wrap (Enum.* on a
  # `{:py_alist, t}` would crash). Returning false routes all
  # iteration consumers through `py_iter_to_list/1`, which has an
  # alist clause that unwraps to a plain list.
  def is_list?(_), do: false

  @spec is_dict?(t()) :: boolean()
  def is_dict?({:dict, _, _}), do: true
  def is_dict?(_), do: false

  @spec is_set?(t()) :: boolean()
  def is_set?({:set}), do: true
  def is_set?(_), do: false

  @spec is_tuple_tag?(t()) :: boolean()
  def is_tuple_tag?({:tuple, _}), do: true
  def is_tuple_tag?(_), do: false

  # ---------------------------------------------------------------------
  # Join (lub) — see "Join rule" in the design doc.
  # ---------------------------------------------------------------------

  @spec lub(t(), t()) :: t()
  def lub(t, t), do: t
  def lub(:any, _), do: :any
  def lub(_, :any), do: :any
  def lub(:bottom, t), do: t
  def lub(t, :bottom), do: t

  # int_lit_nonneg refinement: lub of two nonneg-literals stays nonneg;
  # lub with anything else first promotes nonneg → {:int} and recurses.
  def lub({:int_lit_nonneg}, {:int}), do: {:int}
  def lub({:int}, {:int_lit_nonneg}), do: {:int}
  def lub({:int_lit_nonneg}, other), do: lub({:int}, other)
  def lub(other, {:int_lit_nonneg}), do: lub(other, {:int})

  # numeric tower
  def lub({:int}, {:float}), do: {:float}
  def lub({:float}, {:int}), do: {:float}

  # bool × numeric → union (decision Q7-A; preserves bool-coercion path)
  def lub({:bool}, {:int}), do: union([{:bool}, {:int}])
  def lub({:int}, {:bool}), do: union([{:bool}, {:int}])
  def lub({:bool}, {:float}), do: union([{:bool}, {:float}])
  def lub({:float}, {:bool}), do: union([{:bool}, {:float}])

  # containers
  def lub({:list, a}, {:list, b}), do: {:list, lub(a, b)}
  # Two alists meeting in a phi stay an alist; the element type is
  # the lub of the per-branch element types. Without this clause the
  # type tracker would fall through to `union/1`, which is fine for
  # soundness but kills downstream alist-aware specialisation.
  def lub({:py_alist, a}, {:py_alist, b}), do: {:py_alist, lub(a, b)}
  def lub({:py_pvec, a}, {:py_pvec, b}), do: {:py_pvec, lub(a, b)}
  def lub({:dict, ka, va}, {:dict, kb, vb}), do: {:dict, lub(ka, kb), lub(va, vb)}

  def lub({:tuple, ta}, {:tuple, tb}) when is_list(ta) and is_list(tb) do
    if length(ta) == length(tb) do
      {:tuple, Enum.zip(ta, tb) |> Enum.map(fn {a, b} -> lub(a, b) end)}
    else
      {:tuple, :any_arity}
    end
  end

  def lub({:tuple, _}, {:tuple, _}), do: {:tuple, :any_arity}

  # Phase 7 Q1 — function types: structural lub. Same arity merges
  # param-wise (contravariant glb approximated as lub for soundness;
  # widening params is safe since lub-of-args at call sites already
  # widens). Different arity → `:any`.
  def lub({:fn, pa, ra}, {:fn, pb, rb}) when length(pa) == length(pb) do
    params = Enum.zip(pa, pb) |> Enum.map(fn {a, b} -> lub(a, b) end)
    {:fn, params, lub(ra, rb)}
  end

  def lub({:fn, _, _}, {:fn, _, _}), do: :any

  # unions absorb additional types
  def lub({:union, a}, {:union, b}) do
    union_normalize(MapSet.union(a, b))
  end

  def lub({:union, a}, other), do: union_normalize(MapSet.put(a, other))
  def lub(other, {:union, b}), do: union_normalize(MapSet.put(b, other))

  def lub(a, b), do: union([a, b])

  defp union(types) do
    types |> MapSet.new() |> union_normalize()
  end

  defp union_normalize(set) do
    case MapSet.size(set) do
      0 -> :bottom
      1 -> Enum.at(set, 0)
      _ -> {:union, set}
    end
  end

  # ---------------------------------------------------------------------
  # elem_of — what does iterating / subscripting yield for this type?
  # ---------------------------------------------------------------------

  @spec elem_of(t()) :: t()
  def elem_of({:list, e}), do: e
  def elem_of({:py_alist, e}), do: e
  def elem_of({:py_pvec, e}), do: e
  def elem_of({:str}), do: {:str}
  def elem_of({:tuple, ts}) when is_list(ts), do: lub_all(ts)
  def elem_of({:tuple, :any_arity}), do: :any
  def elem_of({:dict, k, _}), do: k
  def elem_of({:set}), do: :any
  def elem_of(_), do: :any

  @doc """
  `lub` over a list of types. Empty list → `:any` (the conservative
  catch-all; the lattice `:bottom` is internal and should never reach
  callers — see `demote_bottom/1`). Used by inference paths that
  accumulate types across a variable-arity arg list (`min(a, b, c)`,
  `lub_param_types/3` in the fixed-point pass, container-literal
  element inference).
  """
  @spec lub_all([t()]) :: t()
  def lub_all([]), do: :any
  def lub_all(ts), do: Enum.reduce(ts, :bottom, &lub/2) |> demote_bottom()

  @doc """
  `:bottom → :any`, otherwise identity. Public so consumers of the
  lattice (`Pylixir.TypeInfer.Signatures`, `BuiltinSignatures`) never
  expose `:bottom` to callers — only the lattice itself manipulates it.
  """
  @spec demote_bottom(t()) :: t()
  def demote_bottom(:bottom), do: :any
  def demote_bottom(t), do: t

  # ---------------------------------------------------------------------
  # Bind — record a name's type in the current scope (`ctx.types`).
  # ---------------------------------------------------------------------

  @spec bind(Context.t(), String.t(), t()) :: Context.t()
  def bind(%Context{} = ctx, name, type) do
    case lookup_assume(ctx, name) do
      :none ->
        %{ctx | types: Map.put(ctx.types, name, type)}

      {:ok, trace_type} ->
        cond do
          weak_syntactic?(type) ->
            %{ctx | types: Map.put(ctx.types, name, trace_type)}

          type == trace_type ->
            %{ctx | types: Map.put(ctx.types, name, trace_type)}

          true ->
            # Softened A′: concrete-vs-concrete conflict → drop name from
            # assume_types, fall back to existing inference for this and
            # all later binds in this scope.
            ctx = drop_assume(ctx, name)
            %{ctx | types: Map.put(ctx.types, name, type)}
        end
    end
  end

  defp lookup_assume(%Context{assume_types: at, assume_types_scope: scope}, name) do
    case scope do
      nil ->
        :none

      key ->
        case at do
          %{^key => names} ->
            case Map.fetch(names, name) do
              {:ok, t} -> {:ok, t}
              :error -> :none
            end

          _ ->
            :none
        end
    end
  end

  defp drop_assume(%Context{assume_types: at, assume_types_scope: scope} = ctx, name) do
    case scope do
      nil ->
        ctx

      key ->
        case at do
          %{^key => names} ->
            updated_names = Map.delete(names, name)

            updated_at =
              if map_size(updated_names) == 0,
                do: Map.delete(at, key),
                else: Map.put(at, key, updated_names)

            %{ctx | assume_types: updated_at}

          _ ->
            ctx
        end
    end
  end

  defp weak_syntactic?(:any), do: true
  defp weak_syntactic?(:bottom), do: true
  defp weak_syntactic?({:list, :any}), do: true
  defp weak_syntactic?({:dict, :any, :any}), do: true
  defp weak_syntactic?({:tuple, :any_arity}), do: true
  defp weak_syntactic?(_), do: false

  # ---------------------------------------------------------------------
  # bind_pattern — structural destructure binding (decision Q6-A).
  # ---------------------------------------------------------------------

  @spec bind_pattern(map(), t(), Context.t()) :: Context.t()
  def bind_pattern(%{"_type" => "Name", "id" => id}, source_type, ctx) do
    bind(ctx, id, source_type)
  end

  def bind_pattern(%{"_type" => target_type, "elts" => elts}, source_type, ctx)
      when target_type in ["Tuple", "List"] do
    case find_starred(elts) do
      nil -> bind_pattern_no_star(elts, source_type, ctx)
      star_idx -> bind_pattern_with_star(elts, star_idx, source_type, ctx)
    end
  end

  def bind_pattern(
        %{"_type" => "Starred", "value" => inner},
        source_type,
        ctx
      ) do
    bind_pattern(inner, source_type, ctx)
  end

  def bind_pattern(
        %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => coll_id}},
        _source_type,
        ctx
      ) do
    demote(ctx, coll_id)
  end

  def bind_pattern(%{"_type" => "Subscript"}, _source_type, ctx), do: ctx
  def bind_pattern(%{"_type" => "Attribute"}, _source_type, ctx), do: ctx
  def bind_pattern(_other, _source_type, ctx), do: ctx

  defp find_starred(elts) do
    Enum.find_index(elts, fn e -> Map.get(e, "_type") == "Starred" end)
  end

  defp bind_pattern_no_star(elts, {:tuple, ts}, ctx) when is_list(ts) do
    if length(elts) == length(ts) do
      Enum.zip(elts, ts)
      |> Enum.reduce(ctx, fn {e, t}, c -> bind_pattern(e, t, c) end)
    else
      bind_each_any(elts, ctx)
    end
  end

  defp bind_pattern_no_star(elts, {:list, e}, ctx) do
    Enum.reduce(elts, ctx, fn elt, c -> bind_pattern(elt, e, c) end)
  end

  defp bind_pattern_no_star(elts, _other, ctx), do: bind_each_any(elts, ctx)

  defp bind_each_any(elts, ctx) do
    Enum.reduce(elts, ctx, fn elt, c -> bind_pattern(elt, :any, c) end)
  end

  # Position-aware tuple unpack with a Starred elt.
  defp bind_pattern_with_star(elts, star_idx, {:tuple, ts}, ctx) when is_list(ts) do
    n_fixed = length(elts) - 1

    if length(ts) >= n_fixed do
      front = Enum.take(elts, star_idx)
      [starred_elt | rear] = Enum.drop(elts, star_idx)
      n_rear = length(rear)

      front_ts = Enum.take(ts, star_idx)
      rear_ts = if n_rear == 0, do: [], else: Enum.take(ts, -n_rear)

      middle_count = length(ts) - star_idx - n_rear
      middle_ts = Enum.slice(ts, star_idx, middle_count)
      middle_lub = lub_all(middle_ts)

      ctx =
        Enum.zip(front, front_ts)
        |> Enum.reduce(ctx, fn {e, t}, c -> bind_pattern(e, t, c) end)

      ctx = bind_pattern(starred_elt, {:list, middle_lub}, ctx)

      Enum.zip(rear, rear_ts)
      |> Enum.reduce(ctx, fn {e, t}, c -> bind_pattern(e, t, c) end)
    else
      bind_pattern_star_any(elts, ctx)
    end
  end

  defp bind_pattern_with_star(elts, _star_idx, {:list, e}, ctx) do
    Enum.reduce(elts, ctx, fn
      %{"_type" => "Starred", "value" => v}, c -> bind_pattern(v, {:list, e}, c)
      elt, c -> bind_pattern(elt, e, c)
    end)
  end

  defp bind_pattern_with_star(elts, _star_idx, _other, ctx),
    do: bind_pattern_star_any(elts, ctx)

  defp bind_pattern_star_any(elts, ctx) do
    Enum.reduce(elts, ctx, fn
      %{"_type" => "Starred", "value" => v}, c -> bind_pattern(v, {:list, :any}, c)
      elt, c -> bind_pattern(elt, :any, c)
    end)
  end

  # ---------------------------------------------------------------------
  # demote — mutation site Q5-C: container element types become :any.
  # ---------------------------------------------------------------------

  @spec demote(Context.t(), String.t()) :: Context.t()
  def demote(%Context{} = ctx, name) do
    case lookup_assume(ctx, name) do
      {:ok, _} ->
        # Trace-stable name (Q1): skip demotion. The trace observed the
        # final container element type after all mutations.
        ctx

      :none ->
        types = demote_in(ctx.types, name)
        heap_types = demote_in(ctx.heap_types, name)
        %{ctx | types: types, heap_types: heap_types}
    end
  end

  defp demote_in(map, name) do
    case Map.get(map, name) do
      {:list, _} -> Map.put(map, name, {:list, :any})
      {:dict, _, _} -> Map.put(map, name, {:dict, :any, :any})
      _ -> map
    end
  end

  # ---------------------------------------------------------------------
  # infer_expr — read-only type inference for an expression node.
  # ---------------------------------------------------------------------

  @spec infer_expr(nil | map(), Context.t()) :: t()
  def infer_expr(nil, _ctx), do: :any

  def infer_expr(%{"_type" => "Constant", "value" => v}, _ctx), do: constant_type(v)

  def infer_expr(%{"_type" => "Name", "id" => id}, ctx) do
    cond do
      Map.has_key?(ctx.types, id) ->
        Map.fetch!(ctx.types, id)

      Map.has_key?(ctx.heap_types, id) ->
        Map.fetch!(ctx.heap_types, id)

      # Phase 7 Q1 — Name resolves to a user-defined function: produce
      # `{:fn, params, ret}` from fn_signatures. Enables `f` (as a
      # value, e.g. `&f/1` or passed to map) to type as a function.
      sig = Map.get(ctx.fn_signatures, id) ->
        {params, ret} = sig
        {:fn, params, ret}

      true ->
        :any
    end
  end

  def infer_expr(%{"_type" => "List", "elts" => elts}, ctx) do
    {:list, lub_all(Enum.map(elts, &infer_expr(&1, ctx)))}
  end

  def infer_expr(%{"_type" => "Tuple", "elts" => elts}, ctx) do
    {:tuple, Enum.map(elts, &infer_expr(&1, ctx))}
  end

  def infer_expr(%{"_type" => "Set"}, _ctx), do: {:set}

  def infer_expr(%{"_type" => "Dict", "keys" => keys, "values" => values}, ctx) do
    keys = Enum.reject(keys, &is_nil/1)
    k = lub_all(Enum.map(keys, &infer_expr(&1, ctx)))
    v = lub_all(Enum.map(values, &infer_expr(&1, ctx)))
    {:dict, k, v}
  end

  def infer_expr(%{"_type" => "BinOp", "op" => op, "left" => l, "right" => r}, ctx) do
    bin_op_type(op, infer_expr(l, ctx), infer_expr(r, ctx))
  end

  def infer_expr(%{"_type" => "Compare"}, _ctx), do: {:bool}

  def infer_expr(%{"_type" => "BoolOp", "values" => vs}, ctx) do
    lub_all(Enum.map(vs, &infer_expr(&1, ctx)))
  end

  def infer_expr(%{"_type" => "UnaryOp", "op" => op, "operand" => operand}, ctx) do
    ot = infer_expr(operand, ctx)

    case Map.get(op, "_type") do
      "Not" -> {:bool}
      "USub" -> if is_int?(ot), do: {:int}, else: ot
      "UAdd" -> ot
      "Invert" -> if is_int?(ot), do: {:int}, else: :any
      _ -> :any
    end
  end

  def infer_expr(%{"_type" => "IfExp", "body" => b, "orelse" => o}, ctx) do
    lub(infer_expr(b, ctx), infer_expr(o, ctx))
  end

  def infer_expr(%{"_type" => "NamedExpr", "value" => v}, ctx), do: infer_expr(v, ctx)

  def infer_expr(%{"_type" => "Subscript", "value" => val, "slice" => slice}, ctx) do
    case infer_expr(val, ctx) do
      {:list, e} ->
        e

      # decision Q1-B: dict subscript reads return :any to preserve the
      # py_add(nil, n) = n defaultdict idiom.
      {:dict, _, _} ->
        :any

      {:tuple, ts} when is_list(ts) ->
        case slice do
          %{"_type" => "Constant", "value" => i} when is_integer(i) and i >= 0 ->
            Enum.at(ts, i, :any)

          _ ->
            :any
        end

      {:str} ->
        {:str}

      _ ->
        :any
    end
  end

  def infer_expr(%{"_type" => "FormattedValue"}, _ctx), do: {:str}
  def infer_expr(%{"_type" => "JoinedStr"}, _ctx), do: {:str}

  def infer_expr(%{"_type" => "Call", "func" => func} = node, ctx) do
    case func do
      %{"_type" => "Name", "id" => id} ->
        cond do
          # User-defined signatures (PR 9 fixed-point) win over the
          # stdlib table — `def len(xs): return "always"` should shadow.
          sig = Map.get(ctx.fn_signatures, id) ->
            elem(sig, 1)

          true ->
            Pylixir.TypeInfer.BuiltinSignatures.return_type(id, Map.get(node, "args", []), ctx)
        end

      %{"_type" => "Attribute", "attr" => method} ->
        Pylixir.TypeInfer.BuiltinSignatures.method_return_type(method)

      # Phase 7 Q1+Q2 — callee is an expression (curried Call, Lambda
      # literal, parenthesized Name resolving to fn-type, etc.). If
      # the callee's inferred type is `{:fn, _, ret}`, return ret.
      # Otherwise `:any`. Handles `f(a)(b)`, `(lambda x: x)(42)`,
      # and Name lookups that resolve through fn_signatures.
      other ->
        case infer_expr(other, ctx) do
          {:fn, _params, ret} -> ret
          _ -> :any
        end
    end
  end

  # T8 + Phase 7 Q1 — Lambda inference. Python `lambda a, b: <expr>`.
  # Params are primed to `:any` (no call-site info at this point); the
  # body's inferred type becomes the lambda's RETURN type, and the
  # whole lambda types as `{:fn, [:any, ...], body_type}`. Callers that
  # want just the return type (e.g. `function_return_type/2`) unwrap.
  def infer_expr(%{"_type" => "Lambda", "args" => args, "body" => body}, ctx) do
    param_names =
      (Map.get(args, "args") || []) |> Enum.map(&Map.get(&1, "arg"))

    primed = Enum.reduce(param_names, ctx, fn n, c -> bind(c, n, :any) end)
    body_type = infer_expr(body, primed)
    params = List.duplicate(:any, length(param_names))
    {:fn, params, body_type}
  end

  def infer_expr(_other, _ctx), do: :any

  defp constant_type(v) do
    cond do
      is_boolean(v) -> {:bool}
      is_integer(v) and v >= 0 -> {:int_lit_nonneg}
      is_integer(v) -> {:int}
      is_float(v) -> {:float}
      is_binary(v) -> {:str}
      is_nil(v) -> {:none}
      true -> :any
    end
  end

  # ---------------------------------------------------------------------
  # bin_op_type — what type does a BinOp produce, given operand types?
  # Mirrors the table in the design doc. Bool taint inhibits numeric
  # specialization (decision Q7-A / hazard #9).
  # ---------------------------------------------------------------------

  defp bin_op_type(%{"_type" => "Add"}, lt, rt) do
    cond do
      lt == :bottom or rt == :bottom -> :bottom
      bool_tainted?(lt) or bool_tainted?(rt) -> :any
      is_int?(lt) and is_int?(rt) -> {:int}
      numeric_or_int?(lt) and numeric_or_int?(rt) -> {:float}
      is_str?(lt) and is_str?(rt) -> {:str}
      is_list?(lt) and is_list?(rt) -> lub(lt, rt)
      is_tuple_tag?(lt) and is_tuple_tag?(rt) -> {:tuple, :any_arity}
      true -> :any
    end
  end

  defp bin_op_type(%{"_type" => "Sub"}, lt, rt) do
    cond do
      lt == :bottom or rt == :bottom -> :bottom
      bool_tainted?(lt) or bool_tainted?(rt) -> :any
      is_int?(lt) and is_int?(rt) -> {:int}
      numeric_or_int?(lt) and numeric_or_int?(rt) -> {:float}
      true -> :any
    end
  end

  defp bin_op_type(%{"_type" => "Mult"}, lt, rt) do
    cond do
      lt == :bottom or rt == :bottom -> :bottom
      bool_tainted?(lt) or bool_tainted?(rt) -> :any
      is_int?(lt) and is_int?(rt) -> {:int}
      numeric_or_int?(lt) and numeric_or_int?(rt) -> {:float}
      is_str?(lt) and is_int?(rt) -> {:str}
      is_int?(lt) and is_str?(rt) -> {:str}
      is_list?(lt) and is_int?(rt) -> lt
      is_int?(lt) and is_list?(rt) -> rt
      true -> :any
    end
  end

  defp bin_op_type(%{"_type" => "Div"}, _lt, _rt), do: {:float}

  defp bin_op_type(%{"_type" => "FloorDiv"}, lt, rt) do
    cond do
      bool_tainted?(lt) or bool_tainted?(rt) -> :any
      is_int?(lt) and is_int?(rt) -> {:int}
      numeric_or_int?(lt) and numeric_or_int?(rt) -> {:float}
      true -> :any
    end
  end

  defp bin_op_type(%{"_type" => "Mod"}, lt, rt) do
    cond do
      bool_tainted?(lt) or bool_tainted?(rt) -> :any
      is_int?(lt) and is_int?(rt) -> {:int}
      is_str?(lt) -> {:str}
      true -> :any
    end
  end

  defp bin_op_type(%{"_type" => "Pow"}, lt, rt) do
    cond do
      bool_tainted?(lt) or bool_tainted?(rt) -> :any
      is_int?(lt) and is_int?(rt) -> {:int}
      numeric_or_int?(lt) and numeric_or_int?(rt) -> {:float}
      true -> :any
    end
  end

  defp bin_op_type(_op, _lt, _rt), do: :any

  defp numeric_or_int?(t), do: is_int?(t) or t == {:float}
  defp bool_tainted?({:bool}), do: true
  defp bool_tainted?({:union, set}), do: MapSet.member?(set, {:bool})
  defp bool_tainted?(_), do: false

  # Return-type tables for Python builtins, methods, and function-valued
  # AST nodes live in `Pylixir.TypeInfer.BuiltinSignatures`. The Call
  # dispatch in `infer_expr/2` above routes there.

  # ---------------------------------------------------------------------
  # coerce_iter — used by PR 6 iter-consuming sites to drop the
  # `py_iter_to_list/1` wrap when the arg is already statically a list.
  # ---------------------------------------------------------------------

  @spec coerce_iter(Macro.t(), t()) :: Macro.t()
  def coerce_iter(ast, type) do
    if is_list?(type), do: ast, else: {:py_iter_to_list, [], [ast]}
  end

  # ---------------------------------------------------------------------
  # module_summary — seed `ctx.heap_types` from the initial assigns of
  # process-dict-backed names (`ctx.mutable_module_dicts`). PR 3.
  #
  # Container tag only — element types stay `:any` per Q5-C (these names
  # are by definition mutated, so element refinement is unsound).
  # ---------------------------------------------------------------------

  @spec module_summary([map()], Context.t()) :: Context.t()
  def module_summary(runtime_statements, %Context{} = ctx) when is_list(runtime_statements) do
    Enum.reduce(runtime_statements, ctx, &seed_heap_type/2)
  end

  defp seed_heap_type(
         %{
           "_type" => "Assign",
           "targets" => [%{"_type" => "Name", "id" => id}],
           "value" => value
         },
         %Context{mutable_module_dicts: mutable, heap_types: heap_types} = ctx
       ) do
    if MapSet.member?(mutable, id) and not Map.has_key?(heap_types, id) do
      init_type = value |> infer_expr(ctx) |> demote_container_elements()
      %{ctx | heap_types: Map.put(heap_types, id, init_type)}
    else
      ctx
    end
  end

  defp seed_heap_type(_other, ctx), do: ctx

  # ---------------------------------------------------------------------
  # seed_module_attr_types — bind `ctx.types[name]` for each promoted
  # module attribute. `ModuleAnalysis` only promotes values that
  # `Pylixir.LiteralFold` can evaluate, so we route through `fold/1` and
  # then `type_of_term/1` to recover the lattice type. Used by Pipeline
  # pre-pass (was a private helper in `Converter` pre-Pipeline).
  # ---------------------------------------------------------------------

  @spec seed_module_attr_types([{String.t(), map()}], Context.t()) :: Context.t()
  def seed_module_attr_types(attrs, %Context{} = ctx) do
    Enum.reduce(attrs, ctx, fn {name, value_node}, acc ->
      case Pylixir.LiteralFold.fold(value_node) do
        {:ok, value} -> bind(acc, name, type_of_term(value))
        _ -> acc
      end
    end)
  end

  # The bounded fixed-point pass that populates `Context.fn_signatures`
  # lives in `Pylixir.TypeInfer.Signatures`. Entry point:
  # `Pylixir.TypeInfer.Signatures.infer/3`.

  defp demote_container_elements({:list, _}), do: {:list, :any}
  defp demote_container_elements({:dict, _, _}), do: {:dict, :any, :any}

  defp demote_container_elements({:tuple, ts}) when is_list(ts),
    do: {:tuple, Enum.map(ts, fn _ -> :any end)}

  defp demote_container_elements(t), do: t

  # ---------------------------------------------------------------------
  # type_of_term — BEAM term → lattice type. Used by PR 8 (module
  # attribute seeding from `LiteralFold.fold/1` results).
  # ---------------------------------------------------------------------

  @spec type_of_term(term()) :: t()
  def type_of_term(t) when is_boolean(t), do: {:bool}
  def type_of_term(t) when is_integer(t) and t >= 0, do: {:int_lit_nonneg}
  def type_of_term(t) when is_integer(t), do: {:int}
  def type_of_term(t) when is_float(t), do: {:float}
  def type_of_term(t) when is_binary(t), do: {:str}
  def type_of_term(nil), do: {:none}

  def type_of_term(t) when is_list(t) do
    {:list, lub_all(Enum.map(t, &type_of_term/1))}
  end

  def type_of_term(t) when is_tuple(t) do
    {:tuple, t |> Tuple.to_list() |> Enum.map(&type_of_term/1)}
  end

  def type_of_term(%MapSet{}), do: {:set}

  def type_of_term(t) when is_map(t) and not is_struct(t) do
    k = lub_all(Enum.map(Map.keys(t), &type_of_term/1))
    v = lub_all(Enum.map(Map.values(t), &type_of_term/1))
    {:dict, k, v}
  end

  def type_of_term(_), do: :any
end
