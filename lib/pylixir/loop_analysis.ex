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
  @mutation_methods ~w(append sort update add discard clear pop popleft remove extend insert reverse setdefault
                       intersection_update difference_update symmetric_difference_update)

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

  # --- In-place mutation predicate (for-loop element rebuild) -------------

  @doc """
  Whether the loop target `name` is mutated *in place* in `body` such that
  the mutation must propagate back to the source collection — i.e. `body`
  contains a propagating mutation of `name` AND no wholesale rebind of it.

  Propagating ops are exactly those that lower to `name = <op>(name, …)`
  (rebind the root to the mutated value): `name[i]=v`, `name[i]+=v`,
  `name[i][j]=v`, `name[a:b]=…`, `name.<@mutation_methods>(…)` (depth 0/1),
  `del name[i]`. Wholesale rebinds disconnect the final value from the
  source: `name = …`, `for name in …`, `with … as name`, tuple-unpack of
  `name`. Co-occurrence ⇒ FALSE (conservative: rebuild-of-final-value would
  be wrong; fall back to today's codegen).

  `/2` is the structural (typeless) variant — bare-Name augmented assignment
  (`name += …`) is treated as *conservatively propagating* ("might rebuild the
  source", since `list += …` is in-place). Used by `ModuleAnalysis` /
  `LiteralPropagation`, which run before type inference: this guarantees the
  `/2` TRUE-set ⊇ the `/3` TRUE-set, so anything `/3` actually rebuilds is
  already seen as mutated (never promoted/folded). Over-reporting an `int +=`
  no-op is harmless (de-promote / refuse-fold only).

  `/3` additionally takes `name`'s static type (normally the loop's `elem_t`):
  a bare-Name augmented assignment becomes a *propagating* in-place mutation
  (not wholesale) when the type proves a mutable container and `op` is in-place
  for it — list `+=`/`*=`, set `|=`/`&=`/`-=`/`^=`, dict `|=`. Used by codegen.
  """
  @spec target_in_place_mutated?(String.t(), [map()]) :: boolean()
  def target_in_place_mutated?(name, body) when is_binary(name) and is_list(body),
    do: in_place_mutated?(name, body, :structural)

  @spec target_in_place_mutated?(String.t(), [map()], term()) :: boolean()
  def target_in_place_mutated?(name, body, name_type) when is_binary(name) and is_list(body),
    do: in_place_mutated?(name, body, {:typed, name_type})

  @doc """
  Whether `body` wholesale-rebinds the bare Name `name` (`name = …`,
  `name += …`, `for name in …`, `with … as name`, or a tuple-unpack target
  binding `name`). Structural rules — `+=` always counts as a rebind.
  """
  @spec wholesale_rebinds?(String.t(), [map()]) :: boolean()
  def wholesale_rebinds?(name, body) when is_binary(name) and is_list(body) do
    Enum.any?(body, fn node ->
      Walk.walk_scope(node, false, fn n, acc -> acc or wholesale_node?(n, name, :structural) end)
    end)
  end

  defp in_place_mutated?(name, body, mode) do
    {prop, whole} =
      Enum.reduce(body, {false, false}, fn node, acc ->
        Walk.walk_scope(node, acc, fn n, {p, w} ->
          {p or propagating_mutation?(n, name, mode), w or wholesale_node?(n, name, mode)}
        end)
      end)

    prop and not whole
  end

  # Propagating (rebind-the-root) mutations of `name`. All lower to
  # `name = <op>(name, …)`, so the body's final `name` carries the change.
  defp propagating_mutation?(%{"_type" => "Assign", "targets" => targets}, name, _mode) do
    Enum.any?(targets, &subscript_root_is?(&1, name))
  end

  defp propagating_mutation?(
         %{"_type" => "AugAssign", "target" => %{"_type" => "Subscript"} = tgt},
         name,
         _mode
       ),
       do: subscript_root_is?(tgt, name)

  # Bare-Name augmented assign that is in-place for the proven type
  # (`row += xs` on a list, etc.) — propagating only under `/3`.
  defp propagating_mutation?(
         %{"_type" => "AugAssign", "target" => %{"_type" => "Name", "id" => id}, "op" => op},
         name,
         mode
       ),
       do: id == name and inplace_augassign?(op, mode)

  # Statement-context mutation method, receiver rooted at `name` at depth
  # 0 (`name.append(x)`) or depth 1 (`name[i].sort()`).
  defp propagating_mutation?(
         %{
           "_type" => "Expr",
           "value" => %{
             "_type" => "Call",
             "func" => %{"_type" => "Attribute", "value" => recv, "attr" => method}
           }
         },
         name,
         _mode
       )
       when method in @mutation_methods,
       do: mutation_receiver_root(recv) == name

  defp propagating_mutation?(%{"_type" => "Delete", "targets" => targets}, name, _mode) do
    Enum.any?(targets, &subscript_root_is?(&1, name))
  end

  defp propagating_mutation?(_, _, _), do: false

  # Wholesale rebinds — the final `name` is disconnected from the source.
  defp wholesale_node?(%{"_type" => "Assign", "targets" => targets}, name, _mode) do
    Enum.any?(targets, &wholesale_binds?(&1, name))
  end

  defp wholesale_node?(
         %{"_type" => "AugAssign", "target" => %{"_type" => "Name", "id" => id}, "op" => op},
         name,
         mode
       ),
       do: id == name and not inplace_augassign?(op, mode)

  defp wholesale_node?(%{"_type" => type, "target" => tgt}, name, _mode)
       when type in ["For", "AsyncFor"],
       do: wholesale_binds?(tgt, name)

  defp wholesale_node?(%{"_type" => type, "items" => items}, name, _mode)
       when type in ["With", "AsyncWith"] do
    Enum.any?(items, fn item ->
      case Map.get(item, "optional_vars") do
        nil -> false
        vars -> wholesale_binds?(vars, name)
      end
    end)
  end

  defp wholesale_node?(_, _, _), do: false

  # `name[i] = …` / `name[i][j] = …` / `name[a:b] = …` / `del name[i]` —
  # a Subscript target whose base Name is `name`.
  defp subscript_root_is?(%{"_type" => "Subscript", "value" => value}, name),
    do: root_name(value) == name

  defp subscript_root_is?(_, _), do: false

  # Bare-Name binding, including tuple/list unpack targets (`a, b = …`).
  defp wholesale_binds?(%{"_type" => "Name", "id" => id}, name), do: id == name

  defp wholesale_binds?(%{"_type" => type, "elts" => elts}, name)
       when type in ["Tuple", "List"],
       do: Enum.any?(elts, &wholesale_binds?(&1, name))

  defp wholesale_binds?(%{"_type" => "Starred", "value" => v}, name),
    do: wholesale_binds?(v, name)

  defp wholesale_binds?(_, _), do: false

  defp mutation_receiver_root(%{"_type" => "Name", "id" => id}), do: id

  defp mutation_receiver_root(%{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => id}}),
    do: id

  defp mutation_receiver_root(_), do: nil

  # Whether a bare-Name augmented assignment counts as a propagating
  # in-place mutation (vs a disconnecting wholesale rebind).
  #   * `:structural` (typeless) ⇒ TRUE — conservative: `list += …` is
  #     in-place, and without types we must assume it might rebuild the
  #     source (keeps the `/2` ⊇ `/3` superset invariant).
  #   * `{:typed, type}` ⇒ TRUE only when `type` proves a mutable container
  #     and `op` is in-place for it; otherwise FALSE (`int += 1` no-op etc.).
  defp inplace_augassign?(_op, :structural), do: true

  defp inplace_augassign?(%{"_type" => op}, {:typed, type}) do
    case container_kind(type) do
      :list -> op in ["Add", "Mult"]
      :set -> op in ["BitOr", "BitAnd", "Sub", "BitXor"]
      :dict -> op in ["BitOr"]
      :none -> false
    end
  end

  defp container_kind({:list, _}), do: :list
  defp container_kind({:py_alist, _}), do: :list
  defp container_kind({:py_pvec, _}), do: :list
  defp container_kind({:set}), do: :set
  defp container_kind({:dict, _, _}), do: :dict
  defp container_kind(_), do: :none

  defp names_referenced_in(%{"_type" => "Name", "id" => id}), do: MapSet.new([id])

  # Comprehensions are scope boundaries for `walk_scope` — it visits
  # the comp node but doesn't descend. That's correct for *assigned*
  # names (the comp's `for x` target is comp-local and must NOT leak
  # to the surrounding loop's accumulator). But it's wrong for
  # *referenced* names: a comp like `[B[i] for i in range(n)]` inside
  # a while body still reads `B` and `n` from outer scope, and a while
  # rewrite must thread those into the helper signature. Walk the comp
  # manually and subtract its for-target bindings.
  defp names_referenced_in(%{"_type" => type, "elt" => elt, "generators" => generators})
       when type in ["ListComp", "SetComp", "GeneratorExp"],
       do: comp_referenced(generators, [elt])

  defp names_referenced_in(%{
         "_type" => "DictComp",
         "key" => key,
         "value" => value,
         "generators" => generators
       }),
       do: comp_referenced(generators, [key, value])

  defp names_referenced_in(_), do: MapSet.new()

  # Collect Names read from the comp's expressions + each generator's
  # iter (which evaluates in the *enclosing* scope), minus all names
  # bound by `for`-targets across the generators. Generator `ifs`
  # filters DO see the comp-bound names, so they're left as-is —
  # subtracting bound names from the final set is the right shape.
  defp comp_referenced(generators, exprs) do
    bound =
      generators
      |> Enum.flat_map(fn %{"target" => target} -> target_names(target) end)
      |> MapSet.new()

    read =
      generators
      |> Enum.reduce(MapSet.new(), fn gen, acc ->
        iter_reads = collect_names(Map.get(gen, "iter"))

        filter_reads =
          Map.get(gen, "ifs", [])
          |> Enum.reduce(MapSet.new(), &MapSet.union(&2, collect_names(&1)))

        acc |> MapSet.union(iter_reads) |> MapSet.union(filter_reads)
      end)
      |> MapSet.union(Enum.reduce(exprs, MapSet.new(), &MapSet.union(&2, collect_names(&1))))

    MapSet.difference(read, bound)
  end

  # Read-only Name harvest, recursive (no scope barriers — the caller
  # has already handled scope by subtracting bound names). Skips
  # nodes we know don't contain Name reads we care about.
  defp collect_names(%{"_type" => "Name", "id" => id}), do: MapSet.new([id])

  defp collect_names(%{"_type" => type} = node)
       when type in ["ListComp", "SetComp", "GeneratorExp"] do
    elt = Map.get(node, "elt")
    gens = Map.get(node, "generators", [])
    comp_referenced(gens, [elt])
  end

  defp collect_names(%{"_type" => "DictComp"} = node),
    do:
      comp_referenced(Map.get(node, "generators", []), [
        Map.get(node, "key"),
        Map.get(node, "value")
      ])

  defp collect_names(%{} = node) do
    node
    |> Map.delete("_type")
    |> Enum.reduce(MapSet.new(), fn {_k, v}, acc -> MapSet.union(acc, collect_names(v)) end)
  end

  defp collect_names(list) when is_list(list),
    do: Enum.reduce(list, MapSet.new(), &MapSet.union(&2, collect_names(&1)))

  defp collect_names(_), do: MapSet.new()

  defp names_assigned_in(%{"_type" => "Assign", "targets" => targets, "value" => value}) do
    target_set = targets |> Enum.flat_map(&target_names/1) |> MapSet.new()

    # `x = coll.pop()` rebinds `coll` as a side effect (see
    # `Nodes.Assign` capture-return clauses). Mirror that here so
    # loop/if state-tuples thread `coll` out. Same for the heapq
    # capture-return form (recognised via `Stdlib.Heapq`).
    cond do
      coll = pop_capture_root(value) ->
        MapSet.put(target_set, coll)

      match?({:ok, _, _, _}, Pylixir.Stdlib.Heapq.capture_return_call(value, nil)) ->
        {:ok, coll, _, _} = Pylixir.Stdlib.Heapq.capture_return_call(value, nil)
        MapSet.put(target_set, coll)

      true ->
        target_set
    end
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

  # `heapq.heappush(heap, item)` / `heapq.heapify(heap)` and
  # `bisect.insort(xs, v)` (plus bare-Name forms after `from heapq/bisect
  # import …`) rebind their list argument via the Converter's Expr-clause
  # rewrite. For-loop bodies must thread that name through the
  # accumulator — without this, the rebind is discarded each iteration
  # and the list stays at its pre-loop value (eval-corpus seed_3783).
  # Mirrors `ModuleAnalysis.mutates_name?`, which checks both stdlibs.
  defp names_assigned_in(%{"_type" => "Expr", "value" => value}) do
    case Pylixir.Stdlib.Heapq.statement_mutation_call(value, nil) do
      {:ok, name, _, _} ->
        MapSet.new([name])

      _ ->
        case Pylixir.Stdlib.Bisect.statement_mutation_call(value, nil) do
          {:ok, name, _, _} -> MapSet.new([name])
          _ -> MapSet.new()
        end
    end
  end

  # `def f(...): ...` in a runtime / control-flow position is emitted
  # by `Nodes.Functions` as `f = fn ... end` — same binding semantics
  # as an Assign, so the If/For state-tuple must thread `f` out.
  defp names_assigned_in(%{"_type" => "FunctionDef", "name" => name}),
    do: MapSet.new([name])

  defp names_assigned_in(_), do: MapSet.new()

  defp pop_capture_root(%{
         "_type" => "Call",
         "func" => %{
           "_type" => "Attribute",
           "value" => %{"_type" => "Name", "id" => coll},
           "attr" => method
         }
       })
       when method in ["pop", "popleft"],
       do: coll

  defp pop_capture_root(_), do: nil

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
