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

  alias Pylixir.{AST.Walk, Context}

  @max_fixpoint_rounds 5

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
          | {:tuple, [t()] | :any_arity}
          | {:dict, t(), t()}
          | {:set}
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
  def lub({:dict, ka, va}, {:dict, kb, vb}), do: {:dict, lub(ka, kb), lub(va, vb)}

  def lub({:tuple, ta}, {:tuple, tb}) when is_list(ta) and is_list(tb) do
    if length(ta) == length(tb) do
      {:tuple, Enum.zip(ta, tb) |> Enum.map(fn {a, b} -> lub(a, b) end)}
    else
      {:tuple, :any_arity}
    end
  end

  def lub({:tuple, _}, {:tuple, _}), do: {:tuple, :any_arity}

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
  def elem_of({:str}), do: {:str}
  def elem_of({:tuple, ts}) when is_list(ts), do: lub_all(ts)
  def elem_of({:tuple, :any_arity}), do: :any
  def elem_of({:dict, k, _}), do: k
  def elem_of({:set}), do: :any
  def elem_of(_), do: :any

  defp lub_all([]), do: :any
  defp lub_all(ts), do: Enum.reduce(ts, :bottom, &lub/2) |> demote_bottom()

  defp demote_bottom(:bottom), do: :any
  defp demote_bottom(t), do: t

  # ---------------------------------------------------------------------
  # Bind — record a name's type in the current scope (`ctx.types`).
  # ---------------------------------------------------------------------

  @spec bind(Context.t(), String.t(), t()) :: Context.t()
  def bind(%Context{types: types} = ctx, name, type) do
    %{ctx | types: Map.put(types, name, type)}
  end

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
  def demote(%Context{types: types, heap_types: heap_types} = ctx, name) do
    types = demote_in(types, name)
    heap_types = demote_in(heap_types, name)
    %{ctx | types: types, heap_types: heap_types}
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
      Map.has_key?(ctx.types, id) -> Map.fetch!(ctx.types, id)
      Map.has_key?(ctx.heap_types, id) -> Map.fetch!(ctx.heap_types, id)
      true -> :any
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
          sig = Map.get(ctx.fn_signatures, id) -> elem(sig, 1)
          true -> stdlib_return_type(id, Map.get(node, "args", []), ctx)
        end

      _ ->
        :any
    end
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

  # ---------------------------------------------------------------------
  # stdlib_return_type — PR 8. Hardcoded return-type table for Python
  # built-in calls. Argument types feed into iterator-aware returns
  # (sorted preserves element type, enumerate yields {idx, elt}
  # tuples, etc.). Returns `:any` for builtins we don't model.
  # ---------------------------------------------------------------------

  @spec stdlib_return_type(String.t(), [map()], Context.t()) :: t()
  def stdlib_return_type(id, args, ctx) do
    case {id, args} do
      # String/int conversions
      {"int", _} -> {:int}
      {"str", _} -> {:str}
      {"bool", _} -> {:bool}
      {"float", _} -> {:float}
      {"hex", _} -> {:str}
      {"oct", _} -> {:str}
      {"bin", _} -> {:str}
      {"chr", _} -> {:str}
      {"repr", _} -> {:str}
      {"format", _} -> {:str}
      {"ord", _} -> {:int}
      {"abs", _} -> :any
      {"round", _} -> :any
      {"input", _} -> {:str}
      # `len` always returns a non-negative int.
      {"len", _} -> {:int_lit_nonneg}
      # `range(...)` always yields a list of ints (lowered as Enum.to_list of a Range).
      {"range", _} -> {:list, {:int}}
      # `sorted(xs)` preserves the element type.
      {"sorted", [xs | _]} -> {:list, elem_of(infer_expr(xs, ctx))}
      {"sorted", []} -> {:list, :any}
      # `reversed(xs)` likewise.
      {"reversed", [xs]} -> {:list, elem_of(infer_expr(xs, ctx))}
      # `enumerate(xs)` → list of (int, elt) tuples.
      {"enumerate", [xs | _]} -> {:list, {:tuple, [{:int}, elem_of(infer_expr(xs, ctx))]}}
      # `zip(a, b, ...)` → list of tuples (arity = len(args)).
      {"zip", _} -> {:list, {:tuple, :any_arity}}
      # `map`/`filter` — return list with elem from arg.
      {"map", _} -> {:list, :any}
      {"filter", [_, xs]} -> {:list, elem_of(infer_expr(xs, ctx))}
      {"filter", _} -> {:list, :any}
      # `sum` keeps :any (could be int or float; arg-dependent).
      {"sum", _} -> :any
      {"min", [xs]} -> elem_of(infer_expr(xs, ctx))
      {"max", [xs]} -> elem_of(infer_expr(xs, ctx))
      {"min", args_list} -> lub_all(Enum.map(args_list, &infer_expr(&1, ctx)))
      {"max", args_list} -> lub_all(Enum.map(args_list, &infer_expr(&1, ctx)))
      # Container constructors with no args → empty value of that type.
      {"list", []} -> {:list, :any}
      {"list", _} -> {:list, :any}
      {"tuple", _} -> {:tuple, :any_arity}
      {"set", _} -> {:set}
      {"frozenset", _} -> {:set}
      {"dict", _} -> {:dict, :any, :any}
      {"deque", _} -> {:list, :any}
      {"bytearray", _} -> {:list, :any}
      {"bytes", _} -> {:list, :any}
      {"any", _} -> {:bool}
      {"all", _} -> {:bool}
      _ -> :any
    end
  end

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
         %{"_type" => "Assign", "targets" => [%{"_type" => "Name", "id" => id}], "value" => value},
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
  # infer_signatures — PR 9 inter-procedural fixed-point. Iterates
  # `fn_signatures` until stable (capped at MAX_ROUNDS). External
  # callers pin param types; recursive self-calls contribute `:bottom`
  # (excluded from the lub). The body's return type is inferred under
  # the round's primed param bindings.
  # ---------------------------------------------------------------------

  @spec infer_signatures([map()], [map()], Context.t()) :: Context.t()
  def infer_signatures(function_defs, runtime_statements, %Context{} = ctx) do
    typeable_defs = Enum.filter(function_defs, &typeable_def?/1)
    external_sources = build_external_sources(typeable_defs, runtime_statements)

    final_sigs =
      Enum.reduce_while(1..@max_fixpoint_rounds, ctx.fn_signatures, fn _round, sigs ->
        next = compute_round(typeable_defs, external_sources, %{ctx | fn_signatures: sigs})
        if next == sigs, do: {:halt, next}, else: {:cont, next}
      end)

    %{ctx | fn_signatures: final_sigs}
  end

  # Skip variadic / kwarg-bearing defs — caller-arg-position inference
  # doesn't generalize cleanly without param/arity alignment.
  defp typeable_def?(%{"args" => args}) do
    Map.get(args, "vararg") == nil and Map.get(args, "kwarg") == nil
  end

  defp typeable_def?(_), do: false

  defp build_external_sources(function_defs, runtime_statements) do
    Map.new(function_defs, fn %{"name" => name} ->
      others_bodies =
        function_defs
        |> Enum.reject(&(&1["name"] == name))
        |> Enum.flat_map(&(&1["body"] || []))

      {name, others_bodies ++ runtime_statements}
    end)
  end

  defp compute_round(function_defs, external_sources, ctx) do
    Enum.reduce(function_defs, %{}, fn fn_def, acc ->
      name = fn_def["name"]
      param_names = (fn_def["args"]["args"] || []) |> Enum.map(&Map.get(&1, "arg"))
      body = fn_def["body"] || []
      sources = Map.get(external_sources, name, [])

      call_arg_lists = collect_call_args(sources, name)
      param_types = lub_param_types(call_arg_lists, length(param_names), ctx)
      body_ctx = prime_params(ctx, param_names, param_types)
      # Override `name`'s signature to `:bottom` return so recursive
      # calls in the body don't poison the return-type lub. Round (k+1)
      # picks up the proper signature from round k's `acc` snapshot.
      body_ctx = %{
        body_ctx
        | fn_signatures: Map.put(body_ctx.fn_signatures, name, {param_types, :bottom})
      }

      return_type = lub_of_returns(body, body_ctx)

      Map.put(acc, name, {param_types, return_type})
    end)
  end

  defp collect_call_args(nodes, target_name) do
    Walk.walk_scope(nodes, [], fn
      %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => callee}} = call, acc
      when callee == target_name ->
        [Map.get(call, "args", []) | acc]

      _node, acc ->
        acc
    end)
  end

  defp lub_param_types([], n, _ctx), do: List.duplicate(:any, n)

  defp lub_param_types(arg_lists, n, ctx) do
    for i <- 0..(n - 1)//1 do
      arg_lists
      |> Enum.map(fn args -> Enum.at(args, i) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&infer_expr(&1, ctx))
      |> Enum.reduce(:bottom, &lub/2)
      |> demote_bottom()
    end
  end

  defp prime_params(ctx, names, types) do
    pairs = Enum.zip(names, types)
    Enum.reduce(pairs, ctx, fn {name, type}, c -> bind(c, name, type) end)
  end

  defp lub_of_returns(body, ctx) do
    Walk.walk_scope(body, :bottom, fn
      %{"_type" => "Return", "value" => value}, acc when not is_nil(value) ->
        lub(acc, infer_expr(value, ctx))

      %{"_type" => "Return", "value" => nil}, acc ->
        lub(acc, {:none})

      _node, acc ->
        acc
    end)
    |> demote_bottom()
  end

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
