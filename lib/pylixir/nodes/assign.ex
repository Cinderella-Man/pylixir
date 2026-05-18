defmodule Pylixir.Nodes.Assign do
  @moduledoc """
  Owns the lowering for Python `Assign` (`x = expr`, including
  multi-target chains, tuple/list destructure, starred unpack, nested
  subscript writes, and a few stdlib-call shapes whose Assign form is
  irregular: `.pop()` / `.popleft()` / `heapq.heappop()`).

  Two top-level entry points:

    * `assign/2` — `Module.body` Assign node → `{elixir_ast, context}`.
      Dispatches single-target vs multi-target.
    * `rewrite_stdlib_alias_call/2` — pre-Assign-dispatch preprocessor
      that rewrites `bare_name(h)` to `mod.bare_name(h)` when the bare
      name is a `from <mod> import bare_name` alias (`Context.stdlib_aliases`).
      Lets the existing `<mod>.<name>(h)` Assign-clauses fire for the
      aliased shape without duplicating pattern-matches.

  This module is the "Assign node module" in [[CONTEXT.md]] terms,
  parallel to `Loop`, `If`, `Functions`, `Mutations`. Cross-module
  helpers (`Converter.convert`, `bind_name`, `tuple_pattern`,
  `maybe_temp_bind`, `next_temp`, `convert_optional`) live on
  `Pylixir.Converter` and are called back into here.
  """

  alias Pylixir.{Converter, MutableModuleDict, Naming, TypeInfer, UnsupportedNodeError}
  alias Pylixir.AST.Trivial

  @spec assign(map(), Pylixir.Context.t()) :: {Macro.t(), Pylixir.Context.t()}
  def assign(%{"_type" => "Assign", "targets" => targets, "value" => value} = node, context) do
    case targets do
      [single] ->
        single_target_assign(single, rewrite_stdlib_alias_call(value, context), node, context)

      _ ->
        multi_target_assign(targets, value, node, context)
    end
  end

  # --- stdlib-alias preprocessing ---------------------------------------

  @doc """
  If the Call's callee is a stdlib alias (recorded via `from <mod>
  import <name>`), rewrite it to the equivalent `Attribute` shape
  (`<mod>.<name>`). Lets the existing pattern-matching clauses in
  `single_target_assign` (which only know the `<mod>.<name>` shape)
  also work for bare-Name aliased calls. No-op for everything else.

  Exposed publicly because the Expr-statement clause in `Converter`
  needs the same rewrite for bare-Name heapq calls.
  """
  @spec rewrite_stdlib_alias_call(map(), Pylixir.Context.t()) :: map()
  def rewrite_stdlib_alias_call(
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

  def rewrite_stdlib_alias_call(value, _context), do: value

  # --- single-target Assign --------------------------------------------

  # Capture-return form: `x = coll.pop()` / `x = coll.pop(idx_or_key)` /
  # `.pop(key, default)` — Python's mutating capture-and-return pop.
  # Lowers to `{popped, coll} = py_pop_*(coll, ...)` destructure-match.
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
    {arg_asts, context} = Enum.map_reduce(args, context, &Converter.convert/2)
    context = Converter.bind_name(context, id)
    context = Converter.bind_name(context, coll_id)
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

    {arg_asts, context} = Enum.map_reduce(args, context, &Converter.convert/2)
    context = bind_tuple_names!(elts, context)
    context = Converter.bind_name(context, coll_id)

    refs =
      Enum.map(elts, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    head_pattern = Converter.tuple_pattern(refs)
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
    context = Converter.bind_name(context, id)
    context = Converter.bind_name(context, coll_id)
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
    context = Converter.bind_name(context, id)
    context = Converter.bind_name(context, heap_name)
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
    context = Converter.bind_name(context, heap_name)

    head_refs =
      Enum.map(elts, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    head_pattern = Converter.tuple_pattern(head_refs)
    heap_atom = heap_name |> Naming.rewrite() |> String.to_atom()
    heap_ref = {heap_atom, [], nil}
    {{:=, [], [{head_pattern, heap_ref}, {:py_heappop, [], [heap_ref]}]}, context}
  end

  # `x, y = q.popleft()` — tuple-destructure of the deque-head value.
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
    context = Converter.bind_name(context, coll_id)

    refs =
      Enum.map(elts, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    head_pattern = Converter.tuple_pattern(refs)
    coll_atom = coll_id |> Naming.rewrite() |> String.to_atom()
    coll_ref = {coll_atom, [], nil}
    pattern = [{:|, [], [head_pattern, coll_ref]}]
    {{:=, [], [pattern, coll_ref]}, context}
  end

  # `head, *tail = expr` — Python star-unpack destructure.
  defp single_target_assign(%{"_type" => "Tuple", "elts" => elts}, value, node, context) do
    case starred_partition(elts) do
      {:starred, before, star_name, after_elts} ->
        if Enum.all?(before, &match?(%{"_type" => "Name"}, &1)) and
             Enum.all?(after_elts, &match?(%{"_type" => "Name"}, &1)) do
          value_type = TypeInfer.infer_expr(value, context)

          context =
            TypeInfer.bind_pattern(
              %{"_type" => "Tuple", "elts" => elts},
              value_type,
              context
            )

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
            value_type = TypeInfer.infer_expr(value, context)

            context =
              TypeInfer.bind_pattern(%{"_type" => "Tuple", "elts" => elts}, value_type, context)

            {value_ast, context} = Converter.convert(value, context)
            context = bind_destructure_target(elts, context)
            pattern = destructure_pattern(elts)
            {{:=, [], [pattern, value_ast]}, context}

          true ->
            # Mixed Name/Subscript targets (the swap idiom etc.).
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
    cond do
      MapSet.member?(context.mutable_module_dicts, coll_id) and
          not match?(%{"_type" => "Slice"}, slice) ->
        # `memo[k] = v` where `memo` is a module-level mutable dict.
        # Reads of `memo` already lower to `Process.get/1` (Name
        # clause); the write here is the matching `Process.put/2` with
        # the dict-after-setitem as the new value. Slice-assign on
        # mutable dicts isn't meaningful (Python dicts aren't sliceable)
        # so we let the slice branch fall through to the regular path
        # and crash loudly if it ever fires.
        {value_ast, context} = Converter.convert(value, context)
        {slice_ast, context} = Converter.convert(slice, context)
        get = MutableModuleDict.get_ast(coll_id)
        setitem = {:py_setitem, [], [get, slice_ast, value_ast]}
        {MutableModuleDict.put_ast(coll_id, setitem), context}

      true ->
        case slice do
          # Slice-assignment: `coll[start:stop:step] = new_seq`.
          %{"_type" => "Slice"} = slice_node ->
            {value_ast, context} = Converter.convert(value, context)

            {start_ast, context} =
              Converter.convert_optional(Map.get(slice_node, "lower"), context)

            {stop_ast, context} =
              Converter.convert_optional(Map.get(slice_node, "upper"), context)

            {step_ast, context} = Converter.convert_optional(Map.get(slice_node, "step"), context)
            {coll_ast, context} = Converter.convert(collection, context)
            rhs = {:py_slice_assign, [], [coll_ast, start_ast, stop_ast, step_ast, value_ast]}
            context = TypeInfer.demote(context, coll_id)
            context = Converter.bind_name(context, coll_id)
            {{:=, [], [coll_ast, rhs]}, context}

          _ ->
            {value_ast, context} = Converter.convert(value, context)
            {slice_ast, context} = Converter.convert(slice, context)
            {coll_ast, context} = Converter.convert(collection, context)
            setitem = {:py_setitem, [], [coll_ast, slice_ast, value_ast]}
            context = TypeInfer.demote(context, coll_id)
            context = Converter.bind_name(context, coll_id)
            {{:=, [], [coll_ast, setitem]}, context}
        end
    end
  end

  # Nested-subscript assign: `m[a][b]...[z] = v` where the chain bottoms
  # out at a bare Name. Rebind the root via nested `py_setitem` /
  # `py_getitem`.
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
    # Module-level mutable dict — the initial `memo = {…}` lives in
    # runtime statements (py_main); we store the value in the process
    # dict so subsequent `memo[k] = v` writes inside top-level defs
    # can persist. Reads route through `process_dict_get/1` (in
    # Pylixir.Converter). Local rebinds (`memo = something_else` inside
    # a closure) intentionally also go through Process.put — matches
    # Python's `global` semantics for this restricted shape.
    if MapSet.member?(context.mutable_module_dicts, id) do
      {value_ast, context} = Converter.convert(value, context)
      {MutableModuleDict.put_ast(id, value_ast), context}
    else
      # `x = obj.method(args)` where method is a known mutating class
      # method returns `{value, updated_self}` — destructure into both.
      # The non-mutating path stays a plain assign.
      case detect_mutating_method_call(value, context) do
        {:ok, obj_name, class_name, method, args} ->
          {arg_asts, context} = Converter.convert_each(args, context)
          fn_name = Pylixir.Converter.method_fn_name(class_name, method)
          obj_atom = obj_name |> Pylixir.Naming.rewrite() |> String.to_atom()
          obj_ref = {obj_atom, [], nil}
          call = {fn_name, [], [obj_ref | arg_asts]}
          target_atom = id |> Pylixir.Naming.rewrite() |> String.to_atom()
          target_ref = {target_atom, [], nil}
          context = Converter.bind_name(context, obj_name)
          context = Converter.bind_name(context, id)
          pattern = {target_ref, obj_ref}
          {{:=, [], [pattern, call]}, context}

        :no ->
          value_type = TypeInfer.infer_expr(value, context)
          {value_ast, context} = Converter.convert(value, context)
          context = TypeInfer.bind(context, id, value_type)
          context = Converter.bind_name(context, id)
          {target_ast, context} = Converter.convert(target, context)
          {{:=, [], [target_ast, value_ast]}, context}
      end
    end
  end

  # `<obj>.<attr> = expr` where obj is a bare Name. Treated as an
  # instance-map field set: `obj = Map.put(obj, :<attr>, expr)`. Fires
  # for `self.x = ...` inside class methods AND for general
  # `node.children = ...` outside (when classes are in scope; pre-class
  # code would have rejected this entirely). The runtime semantics
  # match Python's instance-attribute assignment for our map-backed
  # instances — `obj` is rebound so subsequent reads see the update.
  defp single_target_assign(
         %{
           "_type" => "Attribute",
           "value" => %{"_type" => "Name", "id" => obj_name},
           "attr" => attr
         } = _target,
         value,
         _node,
         context
       ) do
    {value_ast, context} = Converter.convert(value, context)
    attr_atom = String.to_atom(attr)
    obj_atom = obj_name |> Pylixir.Naming.rewrite() |> String.to_atom()
    obj_ref = {obj_atom, [], nil}

    map_put =
      {{:., [], [{:__aliases__, [], [:Map]}, :put]}, [], [obj_ref, attr_atom, value_ast]}

    context = Converter.bind_name(context, obj_name)
    {{:=, [], [obj_ref, map_put]}, context}
  end

  # `<obj>.<attr>[<slice>] = expr` — collection mutation on an
  # instance attribute. Lowers to
  #   `obj = Map.put(obj, :<attr>, py_setitem(Map.fetch!(obj, :<attr>), slice, expr))`
  # Mirrors the self-attr path; works for both `self.x[i] = v` (inside
  # methods) and `node.children[bit] = v` (outside, treating `node` as
  # an instance map).
  defp single_target_assign(
         %{
           "_type" => "Subscript",
           "value" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => obj_name},
             "attr" => attr
           },
           "slice" => slice
         },
         value,
         _node,
         context
       ) do
    {value_ast, context} = Converter.convert(value, context)
    {slice_ast, context} = Converter.convert(slice, context)
    attr_atom = String.to_atom(attr)
    obj_atom = obj_name |> Pylixir.Naming.rewrite() |> String.to_atom()
    obj_ref = {obj_atom, [], nil}

    attr_read =
      {{:., [], [{:__aliases__, [], [:Map]}, :fetch!]}, [], [obj_ref, attr_atom]}

    new_attr = {:py_setitem, [], [attr_read, slice_ast, value_ast]}

    map_put =
      {{:., [], [{:__aliases__, [], [:Map]}, :put]}, [], [obj_ref, attr_atom, new_attr]}

    context = Converter.bind_name(context, obj_name)
    {{:=, [], [obj_ref, map_put]}, context}
  end

  defp single_target_assign(target, _value, node, _context) do
    raise UnsupportedNodeError,
      node_type: "Assign",
      hint:
        "Assign target shape `#{Map.get(target, "_type")}` is not supported in T13 (non-Name-rooted subscript / Attribute / Starred / slice)",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # --- single-target Assign helpers -------------------------------------
  #
  # `detect_mutating_method_call/2` powers the Name-target clause's
  # `x = obj.method(args)` destructure path (mutating class methods
  # return `{value, updated_self}`). Lives below the catch-all so it
  # doesn't split the `single_target_assign/4` clause cluster.

  defp detect_mutating_method_call(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => obj_name},
             "attr" => method
           },
           "args" => args,
           "keywords" => []
         },
         context
       ) do
    case Map.get(context.class_methods, method, []) do
      [{class_name, :mutating}] -> {:ok, obj_name, class_name, method, args}
      _ -> :no
    end
  end

  defp detect_mutating_method_call(_, _), do: :no

  # --- multi-target Assign (`a = b = c = expr`) ------------------------

  defp multi_target_assign(targets, value, node, context) do
    # Validate target shapes early — reject anything we don't lower.
    Enum.each(targets, fn t ->
      case Map.get(t, "_type") do
        "Name" ->
          :ok

        "Subscript" ->
          :ok

        other ->
          raise UnsupportedNodeError,
            node_type: "Assign",
            hint: "multi-target Assign supports Name and Subscript targets; got `#{other}`",
            lineno: Map.get(node, "lineno"),
            col_offset: Map.get(node, "col_offset")
      end
    end)

    {value_ast, context} = Converter.convert(value, context)

    # Single-eval the value RHS when non-trivial so each target sees the
    # same evaluated value (matches Python: `a = b = expensive()` calls
    # `expensive` once).
    {bindings, value_ref, context} =
      if Trivial.trivial?(value) do
        {[], value_ast, context}
      else
        {temp_atom, context} = Converter.next_temp(context)
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
    context = Converter.bind_name(context, id)
    {{:=, [], [{rewritten, [], nil}, value_ref]}, context}
  end

  defp multi_assign_one(
         %{
           "_type" => "Subscript",
           "value" => %{"_type" => "Name", "id" => coll_id},
           "slice" => slice
         },
         value_ref,
         _node,
         context
       ) do
    {slice_ast, context} = Converter.convert(slice, context)
    coll_atom = coll_id |> Naming.rewrite() |> String.to_atom()
    coll_ref = {coll_atom, [], nil}
    context = Converter.bind_name(context, coll_id)

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

  # --- shared helpers ---------------------------------------------------

  # `.pop()` family RHS — picks the right runtime helper based on arity.
  # 0 args → last element / KeyError on dict (we use py_pop_last for lists);
  # 1 arg  → index for lists, key for dicts; 2 args → key + default for dicts.
  defp pop_call_rhs(coll_ref, []), do: {:py_pop_last, [], [coll_ref]}
  defp pop_call_rhs(coll_ref, [a]), do: {:py_pop_at, [], [coll_ref, a]}
  defp pop_call_rhs(coll_ref, [a, b]), do: {:py_pop_at_default, [], [coll_ref, a, b]}

  defp bind_tuple_names!(elts, context) do
    Enum.reduce(elts, context, fn
      %{"_type" => "Name", "id" => id}, ctx ->
        Converter.bind_name(ctx, id)

      other, _ctx ->
        raise UnsupportedNodeError,
          node_type: "Assign",
          hint:
            "tuple-Assign target requires all elements to be `Name` nodes; got `#{Map.get(other, "_type")}`"
    end)
  end

  # --- mixed-target tuple-Assign (swap idiom etc.) ---------------------

  # `a, b[i] = x, y`-shape where at least one LHS is a depth-1 Subscript
  # rooted at a bare Name. RHS must be a Tuple literal with matching
  # arity (the general-RHS case would need destructure-then-index
  # machinery; not implemented yet).
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
    # mixed case (`y, xs[0] = xs[0], y`) both need it.
    {temps, bindings, context} =
      Enum.reduce(rhs_elts, {[], [], context}, fn rhs, {temps, binds, ctx} ->
        {ast, ctx} = Converter.convert(rhs, ctx)
        {temp_atom, ctx} = Converter.next_temp(ctx)
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
    context = Converter.bind_name(context, id)
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
    {slice_ast, context} = Converter.convert(slice, context)
    {coll_ast, context} = Converter.convert(collection, context)
    setitem = {:py_setitem, [], [coll_ast, slice_ast, temp]}
    context = Converter.bind_name(context, coll_id)
    {{:=, [], [coll_ast, setitem]}, context}
  end

  defp apply_mixed_tuple_target(other, _temp, _context) do
    raise UnsupportedNodeError,
      node_type: "Assign",
      hint:
        "tuple-Assign element shape `#{Map.get(other, "_type")}` is not supported (only Name and depth-1 Subscript)"
  end

  # --- nested-subscript Assign (`m[a][b]…[z] = v`) ---------------------

  defp nested_subscript_chain(%{"_type" => "Subscript", "value" => v, "slice" => s}, acc) do
    case v do
      %{"_type" => "Name", "id" => id} -> {:ok, id, [s | acc]}
      %{"_type" => "Subscript"} = inner -> nested_subscript_chain(inner, [s | acc])
      _ -> :error
    end
  end

  defp target_root_type(%{"_type" => "Subscript", "value" => v}), do: target_root_type(v)
  defp target_root_type(%{"_type" => t}), do: t

  # Two-deep example: `m[a][b] = v` lowers to
  #   m = py_setitem(m, a, py_setitem(py_getitem(m, a), b, v))
  # Slices are temp-bound first to preserve Python's single-eval
  # semantics; the root is a bare Name so re-reading it is safe.
  defp emit_nested_subscript_assign(coll_id, slices, value, context) do
    {value_ast, context} = Converter.convert(value, context)
    {coll_ast, context} = Converter.convert(%{"_type" => "Name", "id" => coll_id}, context)

    {slice_refs, bindings, context} =
      Enum.reduce(slices, {[], [], context}, fn slice_node, {refs, binds, ctx} ->
        {ref, binding, ctx} = Converter.maybe_temp_bind(slice_node, ctx)
        binds = if binding, do: [binding | binds], else: binds
        {[ref | refs], binds, ctx}
      end)

    slice_refs = Enum.reverse(slice_refs)
    bindings = Enum.reverse(bindings)

    new_value = build_nested_setitem(coll_ast, slice_refs, value_ast)
    context = Converter.bind_name(context, coll_id)

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

  # --- nested-tuple destructure (`count, (a, b) = func()`) ------------

  defp pure_destructure_target?(elts) when is_list(elts) do
    Enum.all?(elts, &pure_destructure_elt?/1)
  end

  defp pure_destructure_elt?(%{"_type" => "Name"}), do: true

  defp pure_destructure_elt?(%{"_type" => "Tuple", "elts" => inner}),
    do: pure_destructure_target?(inner)

  defp pure_destructure_elt?(%{"_type" => "List", "elts" => inner}),
    do: pure_destructure_target?(inner)

  defp pure_destructure_elt?(_), do: false

  defp bind_destructure_target(elts, context) when is_list(elts) do
    Enum.reduce(elts, context, fn
      %{"_type" => "Name", "id" => id}, ctx -> Converter.bind_name(ctx, id)
      %{"_type" => "Tuple", "elts" => inner}, ctx -> bind_destructure_target(inner, ctx)
      %{"_type" => "List", "elts" => inner}, ctx -> bind_destructure_target(inner, ctx)
    end)
  end

  defp destructure_pattern(elts) when is_list(elts) do
    refs = Enum.map(elts, &destructure_elt/1)
    Converter.tuple_pattern(refs)
  end

  defp destructure_elt(%{"_type" => "Name", "id" => id}),
    do: {id |> Naming.rewrite() |> String.to_atom(), [], nil}

  defp destructure_elt(%{"_type" => "Tuple", "elts" => inner}), do: destructure_pattern(inner)
  defp destructure_elt(%{"_type" => "List", "elts" => inner}), do: destructure_pattern(inner)

  # --- starred-destructure (`a, *b, c = expr`) -------------------------

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
    value_type = TypeInfer.infer_expr(value, context)
    {value_ast, context} = Converter.convert(value, context)
    star_atom = star_name |> Naming.rewrite() |> String.to_atom()
    context = Converter.bind_name(context, star_name)
    rhs = TypeInfer.coerce_iter(value_ast, value_type)
    {{:=, [], [{star_atom, [], nil}, rhs]}, context}
  end

  defp emit_starred_destructure(before, star_name, [], value, context) do
    value_type = TypeInfer.infer_expr(value, context)
    {value_ast, context} = Converter.convert(value, context)
    {temp_atom, context} = Converter.next_temp(context)
    temp_ref = {temp_atom, [], nil}
    to_list = TypeInfer.coerce_iter(value_ast, value_type)
    bind_temp = {:=, [], [temp_ref, to_list]}

    n_before = length(before)
    star_atom = star_name |> Naming.rewrite() |> String.to_atom()

    before_pattern =
      Enum.map(before, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    context =
      Enum.reduce(before, context, fn %{"_type" => "Name", "id" => id}, ctx ->
        Converter.bind_name(ctx, id)
      end)

    context = Converter.bind_name(context, star_name)

    split = {{:., [], [{:__aliases__, [], [:Enum]}, :split]}, [], [temp_ref, n_before]}
    bind_split = {:=, [], [{before_pattern, {star_atom, [], nil}}, split]}
    {{:__block__, [], [bind_temp, bind_split]}, context}
  end

  defp emit_starred_destructure(before, star_name, after_elts, value, context) do
    value_type = TypeInfer.infer_expr(value, context)
    {value_ast, context} = Converter.convert(value, context)
    {temp_atom, context} = Converter.next_temp(context)
    temp_ref = {temp_atom, [], nil}
    to_list = TypeInfer.coerce_iter(value_ast, value_type)
    bind_temp = {:=, [], [temp_ref, to_list]}

    n_before = length(before)
    n_after = length(after_elts)
    star_atom = star_name |> Naming.rewrite() |> String.to_atom()

    context =
      Enum.reduce(before ++ after_elts, context, fn %{"_type" => "Name", "id" => id}, ctx ->
        Converter.bind_name(ctx, id)
      end)

    context = Converter.bind_name(context, star_name)

    before_pat =
      Enum.map(before, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    after_pat =
      Enum.map(after_elts, fn %{"_type" => "Name", "id" => id} ->
        {id |> Naming.rewrite() |> String.to_atom(), [], nil}
      end)

    {temp2_atom, context} = Converter.next_temp(context)
    temp2_ref = {temp2_atom, [], nil}

    split1 = {{:., [], [{:__aliases__, [], [:Enum]}, :split]}, [], [temp_ref, n_before]}
    bind_split1 = {:=, [], [{before_pat, temp2_ref}, split1]}

    len_temp2 = {{:., [], [{:__aliases__, [], [:Kernel]}, :length]}, [], [temp2_ref]}
    n_star = {:-, [], [len_temp2, n_after]}
    split2 = {{:., [], [{:__aliases__, [], [:Enum]}, :split]}, [], [temp2_ref, n_star]}
    bind_split2 = {:=, [], [{{star_atom, [], nil}, after_pat}, split2]}

    {{:__block__, [], [bind_temp, bind_split1, bind_split2]}, context}
  end
end
