defmodule Pylixir.AlistAnalysis do
  @moduledoc """
  Compile-time safety check for the alist (frozen-list) optimisation.

  Identifies Python variable names whose binding is `xs = list(...)`
  and whose remaining uses in the same scope are read-only enough
  that we can freeze the storage into an O(1)-indexable tuple
  (`{:py_alist, t}`). The frozen value behaves identically to a
  Python list at runtime, but `x[i]` becomes `elem/2` instead of an
  O(n) `Enum.at/2` walk through cons cells.

  See `docs/08_o1-indexed-lists-py-alist.md` for the full design.

  ## Public API

  `freezable_names/1,2` returns the `MapSet.t(String.t())` of names
  that survived every disqualifier. The converter consults this set
  when emitting an Assign to decide whether to wrap the RHS in
  `py_alist_new/1`. The check is strict and conservative — any
  uncertainty makes us bail.

  ## Disqualifiers (mirrors the table in the design doc)

    * Mutation: `xs.append(...)`, `xs[i] = v`, `del xs[i]`, `xs = …`,
      `xs += …`, `for xs in …`, the mutating-stdlib calls (heapq,
      bisect). Detection delegates to
      `Pylixir.ModuleAnalysis.mutates_name?/2`.

    * Leak: any reference to `xs` outside the read-only allowlist —
      aliasing (`y = xs`), container leak (`[xs]`, `(xs, …)`),
      non-allowlisted call (`f(xs)`), `return xs`, `xs + y`, `xs in
      something_else`, etc.

    * Nested-scope mention: even a read-only reference to `xs`
      inside a nested `def`/`lambda`/`class`/comprehension
      disqualifies, because we can't prove the closure doesn't
      mutate.

  ## Debug knobs

    * `PYLIXIR_DISABLE_ALIST=1` — return an empty set unconditionally.
      Escape hatch when something breaks; no rebuild needed.

    * `PYLIXIR_ALIST_DIAG=1` — emit one line per decision to stderr:
      `[alist] f=<scope> x=<name> decision=froze` or
      `[alist] f=<scope> x=<name> decision=bailed reason=<reason>`.
      The eval harness greps these to summarise gate coverage.
  """

  alias Pylixir.AST.Walk
  alias Pylixir.ModuleAnalysis

  # Read-only builtins safe to receive a frozen alist as a single
  # arg. Each either reads-only or produces a fresh regular list.
  # Anything outside this set disqualifies (`f(xs)` for unknown f).
  @read_only_builtins ~w(
    len sum min max any all sorted reversed enumerate zip
    iter list str repr print map filter abs bool
  )

  # Read-only method names — `xs.method(...)` where the receiver is
  # `xs` and the call neither mutates nor leaks the frozen storage.
  # `.copy()` is here because P0 made it produce a fresh regular
  # list (the helper unwraps an alist receiver).
  @read_only_methods ~w(index count copy)

  # AST node types that open a new lexical scope. Walking past these
  # boundaries is the nested-scope detector's job, not the leak
  # detector's.
  @scope_boundary_types ~w(
    FunctionDef AsyncFunctionDef Lambda ClassDef
    ListComp SetComp DictComp GeneratorExp
  )

  @doc """
  Compute the set of freezable names in a scope's statement list.
  `scope_name` is used only for diagnostic logging when
  `PYLIXIR_ALIST_DIAG=1` is set; pass the enclosing function's name,
  or `"(module)"` for module-top.
  """
  @spec freezable_names([map()], String.t()) :: MapSet.t(String.t())
  def freezable_names(body, scope_name \\ "(module)") when is_list(body) do
    if disabled?() do
      MapSet.new()
    else
      body
      |> collect_list_call_bindings()
      |> Enum.group_by(fn {n, _} -> n end, fn {_, node} -> node end)
      |> Enum.flat_map(fn
        # Multiple `xs = list(...)` bindings for the same name is a
        # reassignment by definition — bail without further checks.
        {name, [_, _ | _]} ->
          log_decision(scope_name, name, :bailed, "multiple_list_call_binds")
          []

        {name, [binding]} ->
          if decide(name, body, binding, scope_name), do: [name], else: []
      end)
      |> MapSet.new()
    end
  end

  # === Candidate discovery ===========================================

  # A candidate is a name `xs` bound by `xs = list(<anything>)` at
  # least once in the scope. We deliberately use `Walk.walk_scope/3`
  # so a `list(...)` call inside a nested `def`/`lambda` doesn't
  # count — those are different bindings. Returns the exact AST node
  # of each binding so downstream checks can skip it (the candidate
  # bind itself is not a "mutation" or a "leak").
  defp collect_list_call_bindings(body) do
    body
    |> Enum.flat_map(fn stmt ->
      Walk.walk_scope(stmt, [], fn node, acc ->
        case list_call_binding(node) do
          {:ok, name, exact_node} -> [{name, exact_node} | acc]
          :no -> acc
        end
      end)
    end)
  end

  defp list_call_binding(
         %{
           "_type" => "Assign",
           "targets" => [%{"_type" => "Name", "id" => name}],
           "value" => %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => "list"}}
         } = node
       ),
       do: {:ok, name, node}

  defp list_call_binding(_), do: :no

  # === Per-candidate decision ========================================

  defp decide(name, body, binding_node, scope_name) do
    cond do
      mutated_anywhere?(body, name, binding_node) ->
        log_decision(scope_name, name, :bailed, "mutation")
        false

      leaked?(body, name) ->
        log_decision(scope_name, name, :bailed, "leak_or_alias")
        false

      mentioned_in_nested_scope?(body, name) ->
        log_decision(scope_name, name, :bailed, "nested_scope")
        false

      true ->
        log_decision(scope_name, name, :froze, nil)
        true
    end
  end

  # === Mutation check ================================================

  # Walks each top-level statement scope-aware (stops at nested
  # scopes — those are the nested-scope detector's concern) and
  # delegates to `ModuleAnalysis.mutates_name?/2` for the per-node
  # check. The candidate's own `xs = list(...)` Assign is the only
  # binding (we already rejected names with >1 binding); skip it so
  # the initial bind isn't counted as a reassignment.
  defp mutated_anywhere?(body, name, binding_node) do
    Enum.any?(body, fn stmt ->
      Walk.walk_scope(stmt, false, fn node, acc ->
        cond do
          acc -> acc
          node == binding_node -> acc
          true -> ModuleAnalysis.mutates_name?(node, name)
        end
      end)
    end)
  end

  # === Leak / alias check ============================================

  # Walk each statement looking for a reference to `name` that sits
  # outside the read-only allowlist. We use a slot-aware recursive
  # walker (NOT `walk_scope`) because legality depends on the
  # enclosing parent node — `xs[i]` is fine, `[xs]` is not, even
  # though both contain a bare `Name(xs)`.
  defp leaked?(body, name) do
    Enum.any?(body, &leak_in?(&1, name))
  end

  # The candidate's own `xs = list(<expr>)` Assign — the target
  # `Name(xs)` is the bind site, not a leak. Walk only the value
  # (so `xs = list(xs)` or `xs = list(something_with_xs)` still
  # gets caught via the value descent). A reassignment that matches
  # this shape was already rejected upstream by the "multiple
  # bindings" check, so it never reaches the leak detector.
  defp leak_in?(
         %{
           "_type" => "Assign",
           "targets" => [%{"_type" => "Name", "id" => target_id}],
           "value" => %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => "list"}} = value
         },
         name
       )
       when target_id == name do
    leak_in?(value, name)
  end

  # Subscript: `xs[i]` and `xs[a:b]` are read shapes. The `value`
  # slot may be `Name(xs)` directly without counting as a leak; the
  # `slice` slot is checked normally (any `xs` inside the index
  # expression IS a leak — `xs[xs]` would be).
  defp leak_in?(%{"_type" => "Subscript", "value" => value, "slice" => slice}, name) do
    leak_in_value_slot?(value, name) or leak_in?(slice, name)
  end

  # Compare: only `_ in xs` / `_ not in xs` shapes give the right
  # operand a safe slot. Other operators (`==`, `<`, etc.) checking
  # `xs` mean the value escapes — bail.
  defp leak_in?(
         %{"_type" => "Compare", "left" => left, "ops" => ops, "comparators" => comps},
         name
       ) do
    left_leak = leak_in?(left, name)

    pair_leak =
      ops
      |> Enum.zip(comps)
      |> Enum.any?(fn {op, comp} ->
        case {op, comp} do
          {%{"_type" => kind}, %{"_type" => "Name", "id" => ^name}}
          when kind in ["In", "NotIn"] ->
            false

          _ ->
            leak_in?(comp, name)
        end
      end)

    left_leak or pair_leak
  end

  # For: `for v in xs:` lets `xs` sit in the `iter` slot. body /
  # orelse get walked normally.
  defp leak_in?(
         %{"_type" => "For", "target" => target, "iter" => iter, "body" => body} = node,
         name
       ) do
    orelse = Map.get(node, "orelse", [])

    leak_in_value_slot?(iter, name) or
      leak_in?(target, name) or
      Enum.any?(body, &leak_in?(&1, name)) or
      Enum.any?(orelse, &leak_in?(&1, name))
  end

  # Call to an allowlisted builtin (`len(xs)`, `sum(xs)`, etc.):
  # each direct `Name(xs)` arg is safe. Non-Name arguments get
  # walked (so `len(xs + ys)` leaks via the BinOp).
  defp leak_in?(
         %{
           "_type" => "Call",
           "func" => %{"_type" => "Name", "id" => fname},
           "args" => args
         } = node,
         name
       )
       when fname in @read_only_builtins do
    kws = Map.get(node, "keywords", [])

    args_leak =
      Enum.any?(args, fn arg ->
        case arg do
          %{"_type" => "Name", "id" => ^name} -> false
          _ -> leak_in?(arg, name)
        end
      end)

    args_leak or Enum.any?(kws, &leak_in?(&1, name))
  end

  # Read-only method call on the candidate: `xs.index(v)`,
  # `xs.count(v)`, `xs.copy()`. The receiver `Name(xs)` is safe
  # *only* when the method is in the allowlist AND the receiver is
  # exactly the candidate; otherwise (`other.copy(xs)`, or any
  # non-allowlisted method) we fall through to the generic descent
  # so a `Name(xs)` in the args still flags as a leak.
  defp leak_in?(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => recv_name},
             "attr" => attr
           },
           "args" => args
         } = node,
         name
       )
       when attr in @read_only_methods and recv_name == name do
    kws = Map.get(node, "keywords", [])
    Enum.any?(args, &leak_in?(&1, name)) or Enum.any?(kws, &leak_in?(&1, name))
  end

  # Boundary nodes belong to the nested-scope detector. Stop here
  # so we don't double-report or peer into a different scope.
  defp leak_in?(%{"_type" => type}, _name) when type in @scope_boundary_types, do: false

  # Bare `Name(xs)` not absorbed by any safe-slot clause above is a
  # leak by definition.
  defp leak_in?(%{"_type" => "Name", "id" => id}, name) when id == name, do: true

  # Generic node: descend into every child slot.
  defp leak_in?(%{"_type" => _} = node, name) do
    node
    |> Map.delete("_type")
    |> Enum.any?(fn {_k, v} -> leak_in?(v, name) end)
  end

  defp leak_in?(list, name) when is_list(list) do
    Enum.any?(list, &leak_in?(&1, name))
  end

  defp leak_in?(_leaf, _name), do: false

  # A "value slot" (Subscript.value, For.iter, allowlisted-builtin
  # arg) treats a direct `Name(xs)` as safe but still walks any
  # non-Name expression for transitive leaks.
  defp leak_in_value_slot?(%{"_type" => "Name", "id" => id}, name) when id == name, do: false
  defp leak_in_value_slot?(other, name), do: leak_in?(other, name)

  # === Nested-scope mention check ====================================

  # Sibling to `Walk.walk_scope/3` that *does* descend into boundary
  # nodes. Any mention of `name` inside a nested
  # `def`/`lambda`/`class`/comprehension disqualifies — we can't
  # prove the closure doesn't mutate, so we conservatively bail.
  defp mentioned_in_nested_scope?(body, name) do
    Enum.any?(body, &has_nested_mention?(&1, name))
  end

  defp has_nested_mention?(%{"_type" => type} = node, name) when type in @scope_boundary_types do
    name_mentioned_deep?(node, name)
  end

  defp has_nested_mention?(%{"_type" => _} = node, name) do
    node
    |> Map.delete("_type")
    |> Enum.any?(fn {_k, v} -> has_nested_mention?(v, name) end)
  end

  defp has_nested_mention?(list, name) when is_list(list) do
    Enum.any?(list, &has_nested_mention?(&1, name))
  end

  defp has_nested_mention?(_leaf, _name), do: false

  # Once we're inside a boundary subtree, every Name(name) counts
  # (we don't try to follow Python's shadowing rules — the goal is
  # a strict safety check, not a precise analysis).
  defp name_mentioned_deep?(%{"_type" => "Name", "id" => id}, name) when id == name, do: true

  defp name_mentioned_deep?(%{"_type" => _} = node, name) do
    node
    |> Map.delete("_type")
    |> Enum.any?(fn {_k, v} -> name_mentioned_deep?(v, name) end)
  end

  defp name_mentioned_deep?(list, name) when is_list(list) do
    Enum.any?(list, &name_mentioned_deep?(&1, name))
  end

  defp name_mentioned_deep?(_leaf, _name), do: false

  # === Debug knobs ===================================================

  defp disabled? do
    case System.get_env("PYLIXIR_DISABLE_ALIST") do
      v when v in [nil, "", "0"] -> false
      _ -> true
    end
  end

  defp diag_enabled? do
    case System.get_env("PYLIXIR_ALIST_DIAG") do
      v when v in [nil, "", "0"] -> false
      _ -> true
    end
  end

  defp log_decision(scope, name, :froze, _reason) do
    if diag_enabled?() do
      IO.puts(:stderr, "[alist] f=#{scope} x=#{name} decision=froze")
    end

    :ok
  end

  defp log_decision(scope, name, :bailed, reason) do
    if diag_enabled?() do
      IO.puts(:stderr, "[alist] f=#{scope} x=#{name} decision=bailed reason=#{reason}")
    end

    :ok
  end
end
