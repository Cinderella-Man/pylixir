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

  ## Disqualifiers

  Bail when any of these are true:

    * The bind is anything other than a single `xs = []`. Multiple
      empty-list bindings, list-literal RHS with elements, `list()`
      with args, function-call RHS, etc. all bail.
    * `xs` is reassigned anywhere else (`xs = ...`, `for xs in ...`,
      tuple-destructure target including `xs`).
    * Any mutation other than `.append`: `.pop()`, `.sort()`, `+=`,
      `xs[i] = ...`, `del xs[i]`, …
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

  @spec analyze([map()], String.t()) ::
          {MapSet.t(String.t()), %{non_neg_integer() => MapSet.t(String.t())}}
  def analyze(body, scope_name \\ "(module)") when is_list(body) do
    if disabled?() do
      {MapSet.new(), %{}}
    else
      indexed = Enum.with_index(body)
      binds = collect_empty_list_binds(indexed)

      Enum.reduce(binds, {MapSet.new(), %{}}, fn {name, bind_idx}, {names_acc, fm_acc} ->
        case decide(name, bind_idx, indexed) do
          {:ok, last_mut_idx} ->
            log_decision(scope_name, name, :froze, nil)
            names_acc = MapSet.put(names_acc, name)

            fm_acc =
              Map.update(fm_acc, last_mut_idx, MapSet.new([name]), &MapSet.put(&1, name))

            {names_acc, fm_acc}

          {:bail, reason} ->
            log_decision(scope_name, name, :bailed, reason)
            {names_acc, fm_acc}
        end
      end)
    end
  end

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
          read_indices = for {i, :reads} <- results, do: i

          case {mut_indices, read_indices} do
            {[], _} ->
              {:bail, "no_appends"}

            {_, []} ->
              {:ok, Enum.max(mut_indices)}

            {muts, reads} ->
              last_mut = Enum.max(muts)
              first_read = Enum.min(reads)

              if first_read > last_mut do
                {:ok, last_mut}
              else
                {:bail, "interleaved_read_and_mutation"}
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
  # only read-only uses. `:mixed` is both in the same statement. `:leak`
  # is any disqualifying use.
  defp classify_stmt(stmt, name) do
    counts = collect_uses(stmt, name, %{appends: 0, reads: 0, leaks: 0})

    cond do
      counts.leaks > 0 -> :leak
      counts.appends > 0 and counts.reads > 0 -> :mixed
      counts.appends > 0 -> :mutates
      counts.reads > 0 -> :reads
      true -> :none
    end
  end

  # Slot-aware walker — modelled on `AlistAnalysis.leak_in?/2` but
  # tracks three buckets at once (appends / reads / leaks) instead of
  # short-circuiting on a leak.

  # `xs.append(v)` — statement-form mutation (Expr-wrapped).
  defp collect_uses(
         %{
           "_type" => "Expr",
           "value" => %{
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

  # `xs[i] = v` subscript-assign — disqualifying mutation.
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
        case t do
          %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => ^name}, "slice" => s} ->
            a = bump(a, :leaks)
            collect_uses(s, name, a)

          other ->
            collect_uses(other, name, a)
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
        %{"_type" => "Name", "id" => ^name} -> bump(acc, :leaks)
        %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => ^name}} ->
          bump(acc, :leaks)
        other -> collect_uses(other, name, acc)
      end

    collect_uses(value, name, acc)
  end

  # `del xs[i]` / `del xs`.
  defp collect_uses(%{"_type" => "Delete", "targets" => targets}, name, acc) do
    Enum.reduce(targets, acc, fn t, a ->
      case t do
        %{"_type" => "Name", "id" => ^name} -> bump(a, :leaks)
        %{"_type" => "Subscript", "value" => %{"_type" => "Name", "id" => ^name}} ->
          bump(a, :leaks)
        other -> collect_uses(other, name, a)
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
end
