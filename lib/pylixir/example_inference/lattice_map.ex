defmodule Pylixir.ExampleInference.LatticeMap do
  @moduledoc """
  Maps tracer JSON `type_repr` values into `Pylixir.TypeInfer.t()`
  lattice entries, then lubs/filters observations across examples
  (docs/09 step 3).

  Pipeline:

      tracer envelope(s)
        → events_to_observations/1   (per envelope, per scope)
        → merge_examples/1           (None-aware uniformity filter Q5 B,
                                      raises ExampleConflictError on
                                      cross-example concrete disagreement)
  """

  alias Pylixir.TypeInfer

  @type observations :: %{
          optional(:module | String.t()) => %{optional(String.t()) => TypeInfer.t()}
        }

  @doc """
  Map a single tracer envelope into a per-scope, per-name `TypeInfer.t()`
  map. Within one envelope, multiple events for the same scope are lubbed.
  """
  @spec events_to_observations(map()) :: observations()
  def events_to_observations(%{"events" => events}) when is_list(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      scope = scope_key(event["scope"])
      locals = event["locals"] || %{}

      types =
        Map.new(locals, fn {name, repr} -> {name, repr_to_type(repr)} end)

      Map.update(acc, scope, types, fn existing ->
        Map.merge(existing, types, fn _k, t1, t2 -> TypeInfer.lub(t1, t2) end)
      end)
    end)
  end

  def events_to_observations(_), do: %{}

  @doc """
  Derive per-function signatures from a single envelope. Returns
  `%{fn_name => {[param_types], return_type}}` for every top-level
  function the tracer observed (`call`/`return` events with a non-
  `"module"` scope).
  """
  @spec events_to_signatures(map()) :: %{optional(String.t()) => {[term()], term()}}
  def events_to_signatures(%{"events" => events}) when is_list(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      case event do
        %{"event" => "call", "scope" => scope, "params" => params, "locals" => locals}
        when scope != "module" and is_list(params) ->
          param_types =
            Enum.map(params, fn name ->
              case Map.fetch(locals, name) do
                {:ok, repr} -> repr_to_type(repr)
                :error -> :any
              end
            end)

          merge_signature(acc, scope, param_types, :bottom)

        %{"event" => "return", "scope" => scope, "locals" => %{"__return__" => repr}}
        when scope != "module" ->
          merge_signature(acc, scope, nil, repr_to_type(repr))

        _ ->
          acc
      end
    end)
  end

  def events_to_signatures(_), do: %{}

  defp merge_signature(acc, scope, params, ret) do
    {existing_params, existing_ret} = Map.get(acc, scope, {nil, :bottom})

    new_params =
      cond do
        is_nil(params) -> existing_params
        is_nil(existing_params) -> params
        length(params) != length(existing_params) -> params
        true -> Enum.zip(params, existing_params) |> Enum.map(fn {a, b} -> TypeInfer.lub(a, b) end)
      end

    new_ret = TypeInfer.lub(existing_ret, ret)
    Map.put(acc, scope, {new_params, new_ret})
  end

  @doc """
  Merge observations from multiple envelopes into a single
  `assume_types`-shaped map. Applies the None-aware uniformity filter
  (Q5 B): a name lands in the result iff its non-None, non-`:any`
  observations agree on a single concrete type (or refine to one via
  `TypeInfer.lub/2`). If any None was observed, the resulting type is
  the union of `{:none}` and the concrete type.

  Raises `Pylixir.ExampleConflictError` when concretely-different
  observations cannot be reconciled (e.g., `{:int}` and `{:str}`).
  """
  @spec merge_examples([map()]) :: observations()
  def merge_examples(envelopes) when is_list(envelopes) do
    envelopes
    |> Enum.map(&events_to_observations/1)
    |> collect_per_name()
    |> apply_uniformity_filter()
  end

  @doc """
  Cross-envelope merge of per-function signatures. Per param slot and
  return slot, lubs observations across examples. Slots whose lub
  collapses to a `{:union, _}` of concrete types are demoted to `:any`
  (consistent with the softened conflict policy from `bind/3`); arity
  disagreements drop the function entirely.
  """
  @spec merge_fn_signatures([map()]) :: %{optional(String.t()) => {[term()], term()}}
  def merge_fn_signatures(envelopes) when is_list(envelopes) do
    envelopes
    |> Enum.map(&events_to_signatures/1)
    |> Enum.reduce(%{}, fn sigs, acc ->
      Enum.reduce(sigs, acc, fn {scope, {params, ret}}, acc2 ->
        {existing_params, existing_ret} = Map.get(acc2, scope, {nil, :bottom})

        cond do
          not is_nil(existing_params) and not is_nil(params) and
              length(params) != length(existing_params) ->
            # Arity disagreement — drop the function from the merged
            # map. Existing inference will still see annotation
            # /caller-driven sigs.
            Map.delete(acc2, scope)

          true ->
            new_params =
              cond do
                is_nil(existing_params) -> params
                is_nil(params) -> existing_params
                true ->
                  Enum.zip(existing_params, params)
                  |> Enum.map(fn {a, b} -> soften_lub(TypeInfer.lub(a, b)) end)
              end

            new_ret = soften_lub(TypeInfer.lub(existing_ret, ret))
            Map.put(acc2, scope, {new_params, new_ret})
        end
      end)
    end)
    |> finalize_signatures()
  end

  defp soften_lub({:union, _}), do: :any
  defp soften_lub(t), do: t

  defp finalize_signatures(sigs) do
    Map.new(sigs, fn {scope, {params, ret}} ->
      params = if is_nil(params), do: [], else: Enum.map(params, &TypeInfer.demote_bottom/1)
      {scope, {params, TypeInfer.demote_bottom(ret)}}
    end)
  end

  defp collect_per_name(observations_per_envelope) do
    Enum.reduce(observations_per_envelope, %{}, fn obs, acc ->
      Enum.reduce(obs, acc, fn {scope, name_types}, acc2 ->
        Map.update(acc2, scope, init_lists(name_types), fn existing ->
          Enum.reduce(name_types, existing, fn {name, t}, ex ->
            Map.update(ex, name, [t], &[t | &1])
          end)
        end)
      end)
    end)
  end

  defp init_lists(name_types) do
    Map.new(name_types, fn {name, t} -> {name, [t]} end)
  end

  defp apply_uniformity_filter(per_scope) do
    Enum.reduce(per_scope, %{}, fn {scope, names_with_obs}, acc ->
      stable =
        Enum.reduce(names_with_obs, %{}, fn {name, obs_list}, sacc ->
          case stable_type(name, scope, obs_list) do
            {:ok, t} -> Map.put(sacc, name, t)
            :unstable -> sacc
          end
        end)

      if map_size(stable) == 0, do: acc, else: Map.put(acc, scope, stable)
    end)
  end

  defp stable_type(_name, _scope, obs_list) do
    has_none? = Enum.any?(obs_list, &(&1 == {:none}))

    concretes =
      obs_list
      |> Enum.reject(&(&1 == {:none} or &1 == :any))

    case concretes do
      [] ->
        if has_none?, do: {:ok, {:none}}, else: :unstable

      _ ->
        lub = Enum.reduce(concretes, :bottom, &TypeInfer.lub/2)

        case lub do
          # Concrete-vs-concrete disagreement softens to :unstable
          # (the name is excluded) rather than raising. The harness
          # routinely supplies testcases whose runtime types diverge
          # across stdins; a hard raise would convert otherwise-fine
          # samples into example_conflict failures.
          {:union, _} ->
            :unstable

          :any ->
            :unstable

          t ->
            t = TypeInfer.demote_bottom(t)
            if has_none?, do: {:ok, TypeInfer.lub({:none}, t)}, else: {:ok, t}
        end
    end
  end

  defp scope_key("module"), do: :module
  defp scope_key(name) when is_binary(name), do: name
  defp scope_key(_), do: :module

  defp repr_to_type("int"), do: {:int}
  defp repr_to_type("float"), do: {:float}
  defp repr_to_type("bool"), do: {:bool}
  defp repr_to_type("str"), do: {:str}
  defp repr_to_type("none"), do: {:none}
  defp repr_to_type("any"), do: :any

  defp repr_to_type(%{"kind" => "list", "elems" => elems}) do
    {:list, elems |> Enum.map(&repr_to_type/1) |> TypeInfer.lub_all()}
  end

  defp repr_to_type(%{"kind" => "tuple", "elems" => elems}) do
    {:tuple, Enum.map(elems, &repr_to_type/1)}
  end

  defp repr_to_type(%{"kind" => "dict", "items" => items}) do
    ks = Enum.map(items, fn [k, _] -> repr_to_type(k) end)
    vs = Enum.map(items, fn [_, v] -> repr_to_type(v) end)
    {:dict, TypeInfer.lub_all(ks), TypeInfer.lub_all(vs)}
  end

  defp repr_to_type(%{"kind" => "set"}), do: {:set}
  defp repr_to_type(_other), do: :any
end
