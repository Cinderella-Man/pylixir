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

  @max_rounds 5

  @spec infer([map()], [map()], Context.t()) :: Context.t()
  def infer(function_defs, runtime_statements, %Context{} = ctx) do
    typeable_defs = Enum.filter(function_defs, &typeable_def?/1)
    external_sources = build_external_sources(typeable_defs, runtime_statements)

    final_sigs =
      Enum.reduce_while(1..@max_rounds, ctx.fn_signatures, fn _round, sigs ->
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
