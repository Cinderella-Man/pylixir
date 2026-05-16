defmodule Pylixir.LoopAnalysis do
  @moduledoc """
  Static analysis of a loop body (Python `For.body` or `While.body`)
  determining which Python names get assigned somewhere inside it.

  T16b uses the result to choose between `Enum.each` (no assigned vars
  — pure side-effect loop) and `Enum.reduce` (1+ assigned vars need
  accumulator threading). T18's `While` codegen consumes the same
  result.

  ## Over-thread policy

  Any name that appears as the *target* of one of the following is
  collected — even if the assignment is inside a nested `If`/`For`/
  `While` branch and may only fire on some paths:

    * `Assign` — direct rebinding (including tuple-unpack targets,
      which mention every name they bind).
    * `AugAssign` — `x += 1` (the root name, including subscript /
      attribute roots: `lst[i] += 1` rebinds `lst` per T14's
      `py_setitem` rewrite).
    * `For` target — the loop variable.

  ## Scope barriers

  The walk uses `Pylixir.AST.Walk.walk_scope/3`, which stops at
  `FunctionDef`/`Lambda`/`ClassDef`/comprehension boundaries — those
  have their own scope in Python, so a `def inner(): x = 5` inside the
  loop body does NOT add `x` to the outer assigned_vars.
  """

  alias Pylixir.AST.Walk

  # MapSet is `@opaque`; Dialyzer can't trace that values folded through
  # `Enum.reduce` + `MapSet.union/2` still satisfy the opaque contract.
  # The values *are* MapSets at runtime — this is a known false positive.
  @dialyzer {:nowarn_function, analyze: 1}

  # Same list as `Pylixir.Nodes.Mutations.@methods` — Elixir's flat
  # constants don't compose, so we re-declare here. Drift would mean
  # LoopAnalysis tracks something Mutations doesn't rewrite (or vice
  # versa); the helpers-linkage spirit applies to behavioural pairs
  # like this, but we don't have a programmatic check yet.
  @mutation_methods ~w(append sort update add discard clear pop remove extend insert reverse)

  @type t :: %__MODULE__{
          assigned_vars: MapSet.t(String.t()),
          referenced_vars: MapSet.t(String.t())
        }

  defstruct assigned_vars: MapSet.new(), referenced_vars: MapSet.new()

  @doc """
  Analyse the body of a `For` or `While` loop. Returns a
  `%Pylixir.LoopAnalysis{}` carrying:

    * `:assigned_vars` — names assigned anywhere in the body
      (boundary-respecting).
    * `:referenced_vars` — names *read* anywhere in the body. T18's
      While codegen subtracts the assigned set from this to determine
      read-only outer-scope variables that must be passed through the
      recursive helper.
  """
  @spec analyze([map()]) :: t()
  def analyze(body) when is_list(body) do
    {assigned, referenced} =
      Enum.reduce(body, {MapSet.new(), MapSet.new()}, fn node, {a_acc, r_acc} ->
        Walk.walk_scope(node, {a_acc, r_acc}, fn n, {a, r} ->
          {MapSet.union(a, names_assigned_in(n)), MapSet.union(r, names_referenced_in(n))}
        end)
      end)

    %__MODULE__{assigned_vars: assigned, referenced_vars: referenced}
  end

  defp names_referenced_in(%{"_type" => "Name", "id" => id}), do: MapSet.new([id])
  defp names_referenced_in(_), do: MapSet.new()

  defp names_assigned_in(%{"_type" => "Assign", "targets" => targets}) do
    targets |> Enum.flat_map(&target_names/1) |> MapSet.new()
  end

  defp names_assigned_in(%{"_type" => "AugAssign", "target" => target}) do
    target |> target_names() |> MapSet.new()
  end

  # For-loop targets are *not* added to `assigned_vars`. Pylixir's
  # for-loop emission (`Pylixir.Nodes.Loop`) puts the target in the
  # `Enum.each` / `Enum.reduce` callback's parameter — scope-local to
  # the loop. Threading the target out via a surrounding `if`'s
  # state-tuple produces `row = if … do … row else row end` where
  # `row` isn't in the outer Elixir scope (compile error). The
  # tradeoff: reading the for-loop target *after* the loop in user
  # code (`for x in xs: pass; print(x)`) was already broken for the
  # same reason; this just stops manifesting the breakage as a
  # cryptic if-side compile error.
  defp names_assigned_in(%{"_type" => "For"}), do: MapSet.new()

  # Statement-context mutation methods (`xs.append(x)`, `d.update(o)`,
  # etc.) get rewritten by `Pylixir.Nodes.Mutations` to a reassignment
  # of the root (`xs = xs ++ [x]`). Mirror `ModuleAnalysis` and track
  # those — without this, a body like `for i in xs: results.append(i)`
  # would emit `results = results ++ [i]` inside the Enum.reduce fn
  # without `results` being in the accumulator, so each iteration's
  # update is discarded.
  defp names_assigned_in(%{
         "_type" => "Expr",
         "value" => %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => name},
             "attr" => method
           }
         }
       })
       when method in @mutation_methods,
       do: MapSet.new([name])

  # Same for subscript-rooted mutations: `adj[i].append(x)` rebinds
  # `adj`. Already supported by Mutations + ModuleAnalysis; tracked
  # here so for-loop bodies thread the root through the accumulator.
  defp names_assigned_in(%{
         "_type" => "Expr",
         "value" => %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{
               "_type" => "Subscript",
               "value" => %{"_type" => "Name", "id" => name}
             },
             "attr" => method
           }
         }
       })
       when method in @mutation_methods,
       do: MapSet.new([name])

  # `del coll[k]` — rebinds `coll`.
  defp names_assigned_in(%{"_type" => "Delete", "targets" => targets}) do
    targets
    |> Enum.flat_map(fn
      %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => name}} -> [name]
      _ -> []
    end)
    |> MapSet.new()
  end

  # `heapq.heappush(heap, item)` / `heapq.heapify(heap)` — rebinds
  # `heap` via Pylixir's Expr-clause rewrite. For-loop bodies must
  # thread `heap` through the accumulator.
  defp names_assigned_in(%{
         "_type" => "Expr",
         "value" => %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => "heapq"},
             "attr" => method
           },
           "args" => [%{"_type" => "Name", "id" => name} | _]
         }
       })
       when method in ["heappush", "heapify"],
       do: MapSet.new([name])

  defp names_assigned_in(_), do: MapSet.new()

  # Python's idiomatic throwaway names (`_`, `__`, `___`, …) are *not*
  # tracked as assigned. `_` is Elixir's pattern-only discard; `__`
  # (and any `__<X>__` shape) collides with Elixir's compiler-variable
  # prefix (`__MODULE__`, `__ENV__`, …). Threading any of these out
  # via a surrounding state tuple generates code Elixir's parser
  # rejects. Reading them after a loop is rare and would surface as a
  # clear "undefined variable" instead of the cryptic Elixir error.
  defp target_names(%{"_type" => "Name", "id" => id}) do
    if discard_name?(id), do: [], else: [id]
  end

  defp target_names(%{"_type" => "Tuple", "elts" => elts}),
    do: Enum.flat_map(elts, &target_names/1)

  defp target_names(%{"_type" => "Subscript", "value" => value}),
    do: List.wrap(root_name(value))

  defp target_names(%{"_type" => "Attribute", "value" => value}),
    do: List.wrap(root_name(value))

  defp target_names(_), do: []

  defp root_name(%{"_type" => "Name", "id" => id}), do: id
  defp root_name(%{"_type" => "Subscript", "value" => v}), do: root_name(v)
  defp root_name(%{"_type" => "Attribute", "value" => v}), do: root_name(v)
  defp root_name(_), do: nil

  # `_`, `__`, `___`, …  — all-underscore names are Python's throwaway
  # convention and would all break Elixir's parser in different ways
  # (bare `_` is pattern-only; `__` collides with `__MODULE__` etc.).
  defp discard_name?(id) when is_binary(id),
    do: id != "" and String.to_charlist(id) |> Enum.all?(&(&1 == ?_))
end
