defmodule Pylixir.AppendBuildAnalysis do
  @moduledoc """
  Compile-time analysis that recognises the "append-then-readonly"
  Python idiom and lets the converter freeze the result as an alist
  (see `Pylixir.AlistAnalysis` for the read-only-from-bind variant).

  ## The pattern

      xs = []
      for v in src:
          xs.append(<expr>)
      ...                          # read-only uses of xs follow

  The bind is the literal empty list. The only mutations are
  `xs.append(...)` calls (possibly inside nested for-loops or `if`
  branches). After the last mutating top-level statement, `xs` is
  used read-only.

  ## What the converter does with a positive result

  Two coordinated rewrites:

    1. Inside the build region, `xs.append(v)` is lowered as
       `xs = [v | xs]` (O(1) prepend) instead of the default
       `xs = xs ++ [v]` (O(n)). Makes the build loop O(n) instead of
       O(n²).

    2. Immediately after the last top-level statement that mutates
       `xs`, the converter injects
       `xs = py_alist_new(Enum.reverse(xs))`. The reversed list is
       restored to original order, the result is frozen as a
       `{:py_alist, t}` tagged tuple, and every downstream subscript
       read becomes an O(1) `elem/2` lookup.

  ## Public API

  `analyze/1,2` returns `{names, freeze_after}`:

    * `names :: MapSet.t(String.t())` — names in append-build mode.
      Consulted by `Pylixir.Nodes.Mutations` to choose the prepend
      lowering for `.append`.
    * `freeze_after :: %{non_neg_integer() => MapSet.t(String.t())}` —
      maps a top-level statement index to the set of names whose
      freeze should be injected right after that statement. Consumed
      by the converter's body emission.

  Returns `{MapSet.new(), %{}}` when `PYLIXIR_DISABLE_ALIST=1` (same
  escape hatch as the read-only alist gate — the two analyses share
  a tuning knob since they ship as one optimisation surface).

  ## Tail finalizers

  A single in-place mutation can sit between the last `.append` and
  the read region without disqualifying the candidate. The currently
  recognised finalizer is `xs.sort()` with **no args or kwargs**:

      xs = []
      for v in src:
          xs.append(...)
      xs.sort()                    # tail finalizer
      ...                          # read-only uses follow

  Plain `.sort()` is order-independent on its input, so applying it
  to the reversed prepend-build of `xs` still produces the correct
  sorted list. Stability is only observable via `key=`, so kwargs
  bail (preserves the strict equivalence to the source semantics).

  Per-name kind is recorded in the `freeze_after` value (see below)
  so the converter can choose the right freeze RHS — `Enum.reverse`
  for plain append-build, identity for sort-tail (the sort already
  canonicalized order; reversing would de-sort).

  ## Disqualifiers

  Bail when any of these are true:

    * The bind is anything other than a single `xs = []`. Multiple
      empty-list bindings, list-literal RHS with elements, `list()`
      with args, function-call RHS, etc. all bail.
    * `xs` is reassigned anywhere else (`xs = ...`, `for xs in ...`,
      tuple-destructure target including `xs`).
    * Any mutation other than `.append` or a recognised tail
      finalizer: `.pop()`, `+=`, `xs[i] = ...`, `del xs[i]`,
      `xs.sort(key=...)`, more than one finalizer in a row, …
    * Any leak: `y = xs`, `return xs`, `f(xs)` for non-allowlisted
      `f`, `xs + ys`, `xs in <other>`, `[xs]`, etc.
    * Reads and mutations interleaved in the wrong order — a read
      that happens at a top-level statement index ≤ the last
      mutation index makes the freeze incorrect.

  ## Debug knobs

  Same as `Pylixir.AlistAnalysis`:

    * `PYLIXIR_DISABLE_ALIST=1` — return empty result.
    * `PYLIXIR_ALIST_DIAG=1` — emit `[alist-append] f=… x=… decision=…`
      lines to stderr.
  """

  @read_only_builtins ~w(
    len sum min max any all sorted reversed enumerate zip
    iter list str repr print map filter abs bool
  )

  @read_only_methods ~w(index count copy)

  @typedoc """
  Per-name finalizer kind. `:append_tail` means the build ends with
  `.append` and the freeze must `Enum.reverse` to restore insertion
  order. `:sort_tail` means the build ends with `xs.sort()`, which
  already canonicalized order — the freeze wraps `xs` directly.
  """
  @type freeze_kind :: :append_tail | :sort_tail

  @spec analyze([map()], String.t()) ::
          {MapSet.t(String.t()),
           %{non_neg_integer() => %{optional(String.t()) => freeze_kind()}}}
  def analyze(body, scope_name \\ "(module)") when is_list(body) do
    if disabled?() do
      {MapSet.new(), %{}}
    else
      indexed = Enum.with_index(body)
      binds = collect_empty_list_binds(indexed)

      Enum.reduce(binds, {MapSet.new(), %{}}, fn {name, bind_idx}, {names_acc, fm_acc} ->
        case decide(name, bind_idx, indexed) do
          {:ok, last_mut_idx, kind} ->
            log_decision(scope_name, name, :froze, nil)
            names_acc = MapSet.put(names_acc, name)

            fm_acc =
              Map.update(fm_acc, last_mut_idx, %{name => kind}, &Map.put(&1, name, kind))

            {names_acc, fm_acc}

          {:bail, reason} ->
            log_decision(scope_name, name, :bailed, reason)
            {names_acc, fm_acc}
        end
      end)
    end
  end

  @doc """
  Looser sibling of `analyze/1` returning just the set of names whose
  element type can be safely derived from observed `.append` arguments
  alone — used by `Pylixir.TypeInfer.refine_after_append/3` to enable
  the `:any`-as-`:bottom` lub trick for the empty-list-literal bind.

  Superset of `analyze/1`'s admitted names. Compared to the freeze
  analysis it additionally admits:

    * Nested subscript-assigns `xs[i][...] = v` (`:elem_mutates`) —
      modify inside an existing element, type-preserving for `xs`.
    * Reads interleaved with mutations — ordering doesn't affect the
      lub-of-all-args derivation.
    * Tail-finalizer methods (`.sort()`, `.reverse()` no kwargs)
      anywhere, not just as the final mutation.

  Disqualifiers stay the same as `analyze/1`'s leak rules: direct
  subscript-assign `xs[i] = v` (replaces element, could change type),
  `xs += other` / `.extend(iter)` / `.insert(i, v)` (multi-element
  add — not currently lubbed), alias / return as raw, reassignment,
  method calls outside the safe allowlist.

  Skipped (returns empty set) when `PYLIXIR_DISABLE_ALIST=1`.
  """
  @spec type_refinable_names([map()], String.t()) :: MapSet.t(String.t())
  def type_refinable_names(body, scope_name \\ "(module)") when is_list(body) do
    if disabled?() do
      MapSet.new()
    else
      indexed = Enum.with_index(body)
      binds = collect_empty_list_binds(indexed)

      Enum.reduce(binds, MapSet.new(), fn {name, bind_idx}, acc ->
        if type_refinable?(name, bind_idx, indexed) do
          log_decision(scope_name, name, :type_refinable, nil)
          MapSet.put(acc, name)
        else
          acc
        end
      end)
    end
  end

  defp type_refinable?(name, bind_idx, indexed) do
    not reassigned?(indexed, name, bind_idx) and
      Enum.all?(indexed, fn
        {_stmt, ^bind_idx} -> true
        {stmt, _idx} -> not type_unsafe?(stmt, name)
      end)
  end

  # The pessimistic `collect_uses` `:leaks` rule (bare `Name(name)`
  # anywhere outside a known-safe slot) is too strict for type
  # tracking — it bails on `if not xs:`, `f(xs)`, alias `y = xs`,
  # etc., none of which change `xs`'s element type. Flip the
  # detection: a statement is type-unsafe only if it contains one of
  # the specific patterns that could change `xs`'s element type.
  defp type_unsafe?(stmt, name), do: walk_type_unsafe?(stmt, name)

  # Direct subscript-assign `xs[i] = v` — replaces an element, new
  # element type could differ from prior appends.
  defp walk_type_unsafe?(%{"_type" => "Assign", "targets" => targets, "value" => value}, name) do
    Enum.any?(targets, fn t ->
      direct_subscript_assign_root?(t, name) or walk_type_unsafe?(t, name)
    end) or walk_type_unsafe?(value, name)
  end

  # `xs += other` / `xs[i] += other` — multi-element add, lub of
  # iter elements isn't tracked here. Bail.
  defp walk_type_unsafe?(%{"_type" => "AugAssign", "target" => t, "value" => v}, name) do
    target_root_is_name?(t, name) or walk_type_unsafe?(t, name) or walk_type_unsafe?(v, name)
  end

  # `del xs[i]` / `del xs` — destructive, conservative bail.
  defp walk_type_unsafe?(%{"_type" => "Delete", "targets" => targets}, name) do
    Enum.any?(targets, fn t ->
      target_root_is_name?(t, name) or walk_type_unsafe?(t, name)
    end)
  end

  # `xs.<unsafe_method>(args)` — `extend`, `insert`, etc. add elements
  # we don't lub. `.append`, `.sort`, `.reverse`, `.pop`, `.copy` etc.
  # are type-preserving / type-contributing-in-the-tracked-way.
  defp walk_type_unsafe?(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => recv},
             "attr" => attr
           },
           "args" => args
         } = call,
         name
       )
       when recv == name do
    kws = Map.get(call, "keywords", [])

    cond do
      attr in ["extend", "insert"] -> true
      Enum.any?(args, &walk_type_unsafe?(&1, name)) -> true
      Enum.any?(kws, &walk_type_unsafe?(&1, name)) -> true
      true -> false
    end
  end

  defp walk_type_unsafe?(%{"_type" => _} = node, name) do
    node
    |> Map.delete("_type")
    |> Enum.any?(fn {_k, v} -> walk_type_unsafe?(v, name) end)
  end

  defp walk_type_unsafe?(list, name) when is_list(list),
    do: Enum.any?(list, &walk_type_unsafe?(&1, name))

  defp walk_type_unsafe?(_, _), do: false

  defp target_root_is_name?(%{"_type" => "Name", "id" => id}, name), do: id == name
  defp target_root_is_name?(%{"_type" => "Subscript", "value" => v}, name),
    do: target_root_is_name?(v, name)

  defp target_root_is_name?(_, _), do: false

  # --- candidate discovery -------------------------------------------

  defp collect_empty_list_binds(indexed) do
    indexed
    |> Enum.reduce(%{}, fn {stmt, idx}, acc ->
      case stmt do
        %{
          "_type" => "Assign",
          "targets" => [%{"_type" => "Name", "id" => name}],
          "value" => %{"_type" => "List", "elts" => []}
        } ->
          # Two empty binds of the same name = reassignment; mark.
          Map.update(acc, name, idx, fn _ -> :duplicate end)

        _ ->
          acc
      end
    end)
    |> Enum.flat_map(fn
      {_n, :duplicate} -> []
      {n, i} -> [{n, i}]
    end)
  end

  # --- per-candidate decision ----------------------------------------

  defp decide(name, bind_idx, indexed) do
    if reassigned?(indexed, name, bind_idx) do
      {:bail, "reassigned"}
    else
      results =
        Enum.map(indexed, fn {stmt, idx} ->
          if idx == bind_idx do
            {idx, :bind}
          else
            {idx, classify_stmt(stmt, name)}
          end
        end)

      cond do
        Enum.any?(results, &match?({_, :leak}, &1)) ->
          {:bail, "leak_or_alias"}

        Enum.any?(results, &match?({_, :mixed}, &1)) ->
          {:bail, "interleaved_read_and_mutation"}

        true ->
          mut_indices = for {i, :mutates} <- results, do: i
          finalizer_indices = for {i, :finalizer} <- results, do: i
          read_indices = for {i, :reads} <- results, do: i

          cond do
            length(finalizer_indices) > 1 ->
              {:bail, "multiple_finalizers"}

            mut_indices == [] ->
              {:bail, "no_appends"}

            true ->
              last_append = Enum.max(mut_indices)
              finalizer_idx = List.first(finalizer_indices)

              cond do
                finalizer_idx != nil and finalizer_idx < last_append ->
                  {:bail, "finalizer_before_appends"}

                true ->
                  last_mut = max(last_append, finalizer_idx || -1)

                  first_read =
                    case read_indices do
                      [] -> nil
                      _ -> Enum.min(read_indices)
                    end

                  cond do
                    first_read != nil and first_read <= last_mut ->
                      {:bail, "interleaved_read_and_mutation"}

                    true ->
                      kind = if finalizer_idx != nil, do: :sort_tail, else: :append_tail
                      {:ok, last_mut, kind}
                  end
              end
          end
      end
    end
  end

  # --- reassignment check --------------------------------------------

  defp reassigned?(indexed, name, bind_idx) do
    Enum.any?(indexed, fn {stmt, i} ->
      i != bind_idx and assigns_anywhere?(stmt, name)
    end)
  end

  defp assigns_anywhere?(node, name) do
    walk_any?(node, fn n -> assigns_here?(n, name) end)
  end

  defp assigns_here?(%{"_type" => "Assign", "targets" => targets}, name) do
    Enum.any?(targets, &target_mentions?(&1, name))
  end

  defp assigns_here?(%{"_type" => "AugAssign", "target" => t}, name),
    do: target_mentions?(t, name)

  defp assigns_here?(%{"_type" => "For", "target" => t}, name),
    do: target_mentions?(t, name)

  defp assigns_here?(_, _), do: false

  defp target_mentions?(%{"_type" => "Name", "id" => id}, name), do: id == name

  defp target_mentions?(%{"_type" => "Tuple", "elts" => elts}, name),
    do: Enum.any?(elts, &target_mentions?(&1, name))

  defp target_mentions?(%{"_type" => "List", "elts" => elts}, name),
    do: Enum.any?(elts, &target_mentions?(&1, name))

  defp target_mentions?(%{"_type" => "Starred", "value" => v}, name),
    do: target_mentions?(v, name)

  defp target_mentions?(_, _), do: false

  # --- statement classification --------------------------------------

  # Each top-level statement falls into exactly one category w.r.t.
  # `name`. `:none` is "doesn't mention name at all". `:mutates` means
  # one-or-more `.append`s and no other interaction. `:reads` means
  # only read-only uses. `:finalizer` means a single tail-finalizer
  # method call (currently just bare `xs.sort()`). `:mixed` is two of
  # the above in the same statement. `:leak` is any disqualifying use.
  #
  # `:elem_mutates` (nested subscript-assign `xs[i][...] = v`) is
  # bucketed as `:leak` from the perspective of the alist-freeze
  # analysis below — the lowered `py_setitem(xs, …)` cannot operate
  # on a `{:py_alist, _}`. The looser `type_refinable_names/2`
  # analysis treats it as harmless.
  defp classify_stmt(stmt, name) do
    counts =
      collect_uses(stmt, name, %{
        appends: 0,
        reads: 0,
        leaks: 0,
        finalizers: 0,
        elem_mutates: 0
      })

    cond do
      counts.leaks > 0 -> :leak
      counts.elem_mutates > 0 -> :leak
      mixed?(counts) -> :mixed
      counts.appends > 0 -> :mutates
      counts.finalizers > 0 -> :finalizer
      counts.reads > 0 -> :reads
      true -> :none
    end
  end

  defp mixed?(%{appends: a, reads: r, finalizers: f}) do
    used = (if a > 0, do: 1, else: 0) + (if r > 0, do: 1, else: 0) + (if f > 0, do: 1, else: 0)
    used > 1
  end

  # Slot-aware walker — modelled on `AlistAnalysis.leak_in?/2` but
  # tracks three buckets at once (appends / reads / leaks) instead of
  # short-circuiting on a leak.

  # `xs.append(v)` — statement-form mutation (Expr-wrapped).
  defp collect_uses(
         %{
           "_type" => "Expr",
           "value" =>
             %{
               "_type" => "Call",
               "func" => %{
                 "_type" => "Attribute",
                 "value" => %{"_type" => "Name", "id" => recv},
                 "attr" => "append"
               },
               "args" => args
             } = call
         },
         name,
         acc
       )
       when recv == name do
    # Args walked normally — if an arg contains `Name(xs)` (e.g.
    # `xs.append(xs)` — self-cyclic) that is a leak.
    acc = bump(acc, :appends)
    kws = Map.get(call, "keywords", [])
    acc = Enum.reduce(args, acc, fn a, ac -> collect_uses(a, name, ac) end)
    Enum.reduce(kws, acc, fn k, ac -> collect_uses(k, name, ac) end)
  end

  # `xs.append(v)` as a sub-expression (rare — Python lets `.append`
  # return None, so it could appear in BoolOps. Still treated as an
  # append-mutation in our model; sub-walk args for leaks.)
  defp collect_uses(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => recv},
             "attr" => "append"
           },
           "args" => args
         } = call,
         name,
         acc
       )
       when recv == name do
    acc = bump(acc, :appends)
    kws = Map.get(call, "keywords", [])
    acc = Enum.reduce(args, acc, fn a, ac -> collect_uses(a, name, ac) end)
    Enum.reduce(kws, acc, fn k, ac -> collect_uses(k, name, ac) end)
  end

  # `xs.sort()` with no args and no kwargs — tail finalizer. Plain
  # sort is order-independent on input, so it's safe to apply to the
  # reversed prepend-build of xs. Sort with kwargs (e.g. `key=`) is
  # NOT safe because stability becomes observable on the reversed
  # input; falls through to the generic clause below as a leak.
  defp collect_uses(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => recv},
             "attr" => "sort"
           },
           "args" => []
         } = call,
         name,
         acc
       )
       when recv == name do
    case Map.get(call, "keywords", []) do
      [] -> bump(acc, :finalizers)
      _ -> bump(acc, :leaks)
    end
  end

  # `xs.<other_method>(...)` — any other method call on xs is a leak
  # *unless* the method is in our read-only allowlist. Read-only methods
  # have safe receiver slot; args still walked.
  defp collect_uses(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => recv},
             "attr" => attr
           },
           "args" => args
         } = call,
         name,
         acc
       )
       when recv == name do
    kws = Map.get(call, "keywords", [])

    cond do
      attr in @read_only_methods ->
        acc = bump(acc, :reads)
        acc = Enum.reduce(args, acc, fn a, ac -> collect_uses(a, name, ac) end)
        Enum.reduce(kws, acc, fn k, ac -> collect_uses(k, name, ac) end)

      true ->
        acc = bump(acc, :leaks)
        acc = Enum.reduce(args, acc, fn a, ac -> collect_uses(a, name, ac) end)
        Enum.reduce(kws, acc, fn k, ac -> collect_uses(k, name, ac) end)
    end
  end

  # `xs[i]` / `xs[a:b]` — read shape. Receiver slot safe; slice walked.
  defp collect_uses(%{"_type" => "Subscript", "value" => value, "slice" => slice}, name, acc) do
    acc =
      case value do
        %{"_type" => "Name", "id" => ^name} -> bump(acc, :reads)
        other -> collect_uses(other, name, acc)
      end

    collect_uses(slice, name, acc)
  end

  # `v in xs` / `v not in xs` — read shape; left walked, comparator
  # right-hand slot safe only for in/not-in.
  defp collect_uses(
         %{"_type" => "Compare", "left" => left, "ops" => ops, "comparators" => comps},
         name,
         acc
       ) do
    acc = collect_uses(left, name, acc)

    Enum.zip(ops, comps)
    |> Enum.reduce(acc, fn {op, comp}, a ->
      case {op, comp} do
        {%{"_type" => kind}, %{"_type" => "Name", "id" => ^name}}
        when kind in ["In", "NotIn"] ->
          bump(a, :reads)

        _ ->
          collect_uses(comp, name, a)
      end
    end)
  end

  # `for v in xs` — iter slot safe; target / body / orelse walked.
  defp collect_uses(
         %{"_type" => "For", "target" => target, "iter" => iter, "body" => body} = node,
         name,
         acc
       ) do
    orelse = Map.get(node, "orelse", [])

    acc =
      case iter do
        %{"_type" => "Name", "id" => ^name} -> bump(acc, :reads)
        other -> collect_uses(other, name, acc)
      end

    acc = collect_uses(target, name, acc)
    acc = Enum.reduce(body, acc, fn n, a -> collect_uses(n, name, a) end)
    Enum.reduce(orelse, acc, fn n, a -> collect_uses(n, name, a) end)
  end

  # `f(xs)` where f is an allowlisted builtin (`len(xs)`, `sum(xs)`, etc.).
  defp collect_uses(
         %{
           "_type" => "Call",
           "func" => %{"_type" => "Name", "id" => fname},
           "args" => args
         } = call,
         name,
         acc
       )
       when fname in @read_only_builtins do
    kws = Map.get(call, "keywords", [])

    acc =
      Enum.reduce(args, acc, fn arg, a ->
        case arg do
          %{"_type" => "Name", "id" => ^name} -> bump(a, :reads)
          other -> collect_uses(other, name, a)
        end
      end)

    Enum.reduce(kws, acc, fn k, a -> collect_uses(k, name, a) end)
  end

  # `xs[i] = v` direct subscript-assign — disqualifying mutation.
  # Replaces an element entirely, so the element type could change.
  defp collect_uses(
         %{
           "_type" => "Assign",
           "targets" => targets,
           "value" => value
         },
         name,
         acc
       ) do
    acc =
      Enum.reduce(targets, acc, fn t, a ->
        cond do
          direct_subscript_assign_root?(t, name) ->
            a = bump(a, :leaks)
            collect_uses(slice_of(t), name, a)

          nested_subscript_assign_root?(t, name) ->
            # `xs[i][...] = v` — chain rooted at Name(`name`), depth >= 2.
            # Modifies INSIDE an existing element, doesn't change xs's
            # element TYPE. Bumps a separate bucket: disqualifying for
            # the alist-freeze (we'd lower to `py_setitem(xs, …)` which
            # has no clause for `{:py_alist, _}`) but admitted by the
            # looser `type_refinable_names/2` analysis below.
            a = bump(a, :elem_mutates)
            walk_subscript_chain_slices(t, name, a)

          true ->
            collect_uses(t, name, a)
        end
      end)

    collect_uses(value, name, acc)
  end

  # `xs += ...` augmented assign.
  defp collect_uses(
         %{"_type" => "AugAssign", "target" => target, "value" => value},
         name,
         acc
       ) do
    acc =
      case target do
        %{"_type" => "Name", "id" => ^name} ->
          bump(acc, :leaks)

        %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => ^name}} ->
          bump(acc, :leaks)

        other ->
          collect_uses(other, name, acc)
      end

    collect_uses(value, name, acc)
  end

  # `del xs[i]` / `del xs`.
  defp collect_uses(%{"_type" => "Delete", "targets" => targets}, name, acc) do
    Enum.reduce(targets, acc, fn t, a ->
      case t do
        %{"_type" => "Name", "id" => ^name} ->
          bump(a, :leaks)

        %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => ^name}} ->
          bump(a, :leaks)

        other ->
          collect_uses(other, name, a)
      end
    end)
  end

  # Bare `Name(xs)` not absorbed by a safe-slot clause above = leak.
  defp collect_uses(%{"_type" => "Name", "id" => id}, name, acc) when id == name do
    bump(acc, :leaks)
  end

  # Generic descent — walk every child slot.
  defp collect_uses(%{"_type" => _} = node, name, acc) do
    node
    |> Map.delete("_type")
    |> Enum.reduce(acc, fn {_k, v}, a -> collect_uses(v, name, a) end)
  end

  defp collect_uses(list, name, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_uses(&1, name, &2))
  end

  defp collect_uses(_, _, acc), do: acc

  defp direct_subscript_assign_root?(
         %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => id}},
         name
       ),
       do: id == name

  defp direct_subscript_assign_root?(_, _), do: false

  defp nested_subscript_assign_root?(
         %{"_type" => "Subscript", "value" => %{"_type" => "Subscript"} = inner},
         name
       ),
       do: subscript_chain_root?(inner, name)

  defp nested_subscript_assign_root?(_, _), do: false

  defp subscript_chain_root?(%{"_type" => "Subscript", "value" => v}, name),
    do: subscript_chain_root?(v, name)

  defp subscript_chain_root?(%{"_type" => "Name", "id" => id}, name), do: id == name
  defp subscript_chain_root?(_, _), do: false

  defp slice_of(%{"_type" => "Subscript", "slice" => s}), do: s

  defp walk_subscript_chain_slices(
         %{"_type" => "Subscript", "value" => v, "slice" => s},
         name,
         acc
       ) do
    acc = collect_uses(s, name, acc)
    walk_subscript_chain_slices(v, name, acc)
  end

  defp walk_subscript_chain_slices(_, _, acc), do: acc

  defp bump(acc, key), do: Map.update!(acc, key, &(&1 + 1))

  # --- generic walk ---------------------------------------------------

  defp walk_any?(%{"_type" => _} = node, pred) do
    if pred.(node) do
      true
    else
      node
      |> Map.delete("_type")
      |> Enum.any?(fn {_k, v} -> walk_any?(v, pred) end)
    end
  end

  defp walk_any?(list, pred) when is_list(list), do: Enum.any?(list, &walk_any?(&1, pred))
  defp walk_any?(_, _), do: false

  # --- debug knobs ----------------------------------------------------

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
      IO.puts(:stderr, "[alist-append] f=#{scope} x=#{name} decision=froze")
    end

    :ok
  end

  defp log_decision(scope, name, :bailed, reason) do
    if diag_enabled?() do
      IO.puts(:stderr, "[alist-append] f=#{scope} x=#{name} decision=bailed reason=#{reason}")
    end

    :ok
  end

  defp log_decision(scope, name, :type_refinable, _reason) do
    if diag_enabled?() do
      IO.puts(:stderr, "[alist-append] f=#{scope} x=#{name} decision=type_refinable")
    end

    :ok
  end
end
