defmodule Pylixir.TypeInfer.Signatures do
  @moduledoc """
  Bounded fixed-point inter-procedural inference. Runs once from
  `Pylixir.Converter`'s Module clause to populate
  `Context.fn_signatures` with `{param_types, return_type}` per
  top-level user-defined function. See
  `docs/02_type-inference-monomorphization.md` (Q3-C) for the design.

  Convergence rules:

    * External call sites pin param types via lub. Recursive (in-body)
      self-calls are EXCLUDED from the lub — they only re-assert
      whatever external callers already typed, and including them
      would poison the iteration with `:any` from a yet-untyped body.
    * Each round overrides the in-flight function's signature to
      `{param_types, :bottom}` so its recursive calls return `:bottom`
      (which lub's cleanly with concrete types), letting return-type
      inference converge through repeated rounds.
    * Bounded at `@max_rounds` iterations. Recursive functions
      typically stabilize in 2–3 rounds (`fib(int) → int`).

  Public entry point: `infer/3`.
  """

  alias Pylixir.{AST.Walk, Context, TypeInfer}
  alias Pylixir.TypeInfer.Annotation

  @max_rounds 5

  @spec infer([map()], [map()], Context.t()) :: Context.t()
  def infer(function_defs, runtime_statements, %Context{} = ctx) do
    typeable_defs = Enum.filter(function_defs, &typeable_def?/1)
    external_sources = build_external_sources(typeable_defs, runtime_statements)
    annotated_sigs = collect_annotated_sigs(typeable_defs)
    initial_sigs = seed_fn_signatures(ctx.fn_signatures, annotated_sigs)

    final_sigs =
      Enum.reduce_while(1..@max_rounds, initial_sigs, fn _round, sigs ->
        next =
          compute_round(
            typeable_defs,
            external_sources,
            %{ctx | fn_signatures: sigs},
            annotated_sigs
          )

        if next == sigs, do: {:halt, next}, else: {:cont, next}
      end)

    %{ctx | fn_signatures: final_sigs}
  end

  # Collect annotation-derived param / return types per FunctionDef.
  # Result shape: `%{name => {param_types, return_type}}` where each
  # type is `:any` if the corresponding annotation is absent or maps
  # to `:any` via `Annotation.annotation_to_type/1`.
  defp collect_annotated_sigs(defs) do
    Map.new(defs, fn def_node ->
      name = def_node["name"]
      args = Map.get(def_node["args"], "args", [])
      param_anns = Enum.map(args, fn arg -> Annotation.annotation_to_type(arg["annotation"]) end)
      return_ann = Annotation.annotation_to_type(def_node["returns"])
      {name, {param_anns, return_ann}}
    end)
  end

  # Pre-seed `fn_signatures` so that round 1's inference of OTHER
  # functions calling annotated ones picks up the annotated sig.
  # Only seed entries that have at least one non-`:any` annotation;
  # all-`:any` entries don't carry new info and are skipped (the
  # fixpoint will produce them via inference anyway).
  defp seed_fn_signatures(existing, annotated_sigs) do
    Enum.reduce(annotated_sigs, existing, fn {name, {params, ret}}, acc ->
      if has_annotation?(params, ret),
        do: Map.put(acc, name, {params, ret}),
        else: acc
    end)
  end

  defp has_annotation?(params, ret), do: ret != :any or Enum.any?(params, &(&1 != :any))

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

  defp compute_round(function_defs, external_sources, ctx, annotated_sigs) do
    Enum.reduce(function_defs, %{}, fn fn_def, acc ->
      name = fn_def["name"]
      param_names = (fn_def["args"]["args"] || []) |> Enum.map(&Map.get(&1, "arg"))
      body = fn_def["body"] || []
      sources = Map.get(external_sources, name, [])

      call_arg_lists = collect_call_args(sources, name)
      inferred_params = lub_param_types(call_arg_lists, length(param_names), ctx)
      {ann_params, ann_ret} = Map.get(annotated_sigs, name, {[], :any})
      param_types = merge_annotated(ann_params, inferred_params)
      body_ctx = prime_params(ctx, param_names, param_types)
      # Override `name`'s signature to `:bottom` return so recursive
      # calls in the body don't poison the return-type lub. Round (k+1)
      # picks up the proper signature from round k's `acc` snapshot.
      body_ctx = %{
        body_ctx
        | fn_signatures: Map.put(body_ctx.fn_signatures, name, {param_types, :bottom})
      }

      inferred_return = lub_of_returns(body, body_ctx)
      return_type = if ann_ret == :any, do: inferred_return, else: ann_ret

      Map.put(acc, name, {param_types, return_type})
    end)
  end

  # Per-slot merge: annotation wins when present (non-`:any`); fall back
  # to inferred otherwise. Lengths match by construction (collected
  # over the same arg list).
  defp merge_annotated([], inferred), do: inferred

  defp merge_annotated(annotated, inferred) do
    Enum.zip(annotated, inferred)
    |> Enum.map(fn
      {:any, i} -> i
      {a, _i} -> a
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
      |> Enum.map(&TypeInfer.infer_expr(&1, ctx))
      |> Enum.reduce(:bottom, &TypeInfer.lub/2)
      |> TypeInfer.demote_bottom()
    end
  end

  defp prime_params(ctx, names, types) do
    pairs = Enum.zip(names, types)
    Enum.reduce(pairs, ctx, fn {name, type}, c -> TypeInfer.bind(c, name, type) end)
  end

  defp lub_of_returns(body, ctx) do
    Walk.walk_scope(body, :bottom, fn
      %{"_type" => "Return", "value" => value}, acc when not is_nil(value) ->
        TypeInfer.lub(acc, TypeInfer.infer_expr(value, ctx))

      %{"_type" => "Return", "value" => nil}, acc ->
        TypeInfer.lub(acc, {:none})

      _node, acc ->
        acc
    end)
    |> TypeInfer.demote_bottom()
  end
end
