defmodule Dataset.Verify do
  @moduledoc """
  Stage 2 — the verification gate. See docs/12_dataset-curation-plan.md
  §What-verified, §Pipeline-2.

  A `(solution, testcase)` is kept iff BOTH:

    1. **Reproducible** — run the solution on the testcase's stdin
       `run_count` times (default 5); every run must produce
       byte-identical output after `Dataset.Normalize`. Any variation
       (unseeded RNG, wall-clock, set/dict iteration order) → drop.
    2. **Correct** — that reproducible canonical output equals **at
       least one** of the testcase's stored `expecteds` (after
       normalization). rStar noise / alternate-valid means a stdin can
       carry several stored outputs; matching any one confirms the
       solution's output is legitimate.

  The canonical shipped `expected` is the solution's normalized output.

  Reproducibility verdicts are cached per `(source, stdin)` in
  `Dataset.PythonCache` (ETS + JSONL) so restarts skip completed work and
  solutions sharing identical behavior reuse results. The correctness
  match is computed in-memory (it depends on the testcase's `expecteds`,
  not just the source/stdin) and is not cached.

  Output is capped relative to the stored expected size
  (`max(expected) + 1 MB`) so a runaway program is killed without
  truncating a legitimately large answer.
  """

  alias Dataset.{Execute, Normalize, PythonCache}

  @run_count 5
  @timeout_ms 20_000
  @output_headroom 1024 * 1024

  @type verdict :: {:reproducible, String.t()} | {:rejected, atom()}

  @doc """
  Verify one solution against a list of candidate testcases (already
  capped/sorted by the caller). Returns the **kept** testcases as
  shippable maps `%{stdin, expected, n_stored_outputs}` where `expected`
  is the canonical (solution's normalized) output.

  **Short-circuits at the first failed testcase** — a solution that fails
  any testcase can't be the "verifies all" winner, so we stop rather than
  paying for the rest. The returned list therefore has `length == #(input
  testcases)` iff the solution verified them all (what `Dataset.Select`'s
  early-stop checks); a losing solution returns its verified *prefix*
  (used only as an approximate count in the no-winner fallback).

  ## Options
    * `:run_count` (default #{@run_count})
    * `:timeout_ms` (default #{@timeout_ms})
    * `:python`
  """
  @spec verify_solution(%{source: String.t()}, [map()], keyword()) :: [map()]
  def verify_solution(%{source: source}, testcases, opts \\ []) do
    testcases
    |> Enum.reduce_while([], fn tc, kept ->
      case verify_testcase(source, tc, opts) do
        {:keep, canonical} ->
          {:cont, [%{stdin: tc.stdin, expected: canonical, n_stored_outputs: tc.n_stored_outputs} | kept]}

        {:drop, _reason} ->
          {:halt, kept}
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Verify a single `(source, testcase)`. Returns `{:keep, canonical}` or
  `{:drop, reason}`.
  """
  @spec verify_testcase(String.t(), map(), keyword()) ::
          {:keep, String.t()} | {:drop, atom()}
  def verify_testcase(source, %{stdin: stdin, expecteds: expecteds}, opts \\ []) do
    sha = PythonCache.key(source, stdin)
    cap = output_cap(expecteds)
    run_opts = single_run_opts(opts, stdin, cap)
    run_count = Keyword.get(opts, :run_count, @run_count)

    case PythonCache.lookup(sha) do
      {:hit, entry} ->
        case decode_verdict(entry) do
          {:reproducible, c} ->
            keep_or_mismatch(c, expecteds)

          {:rejected, reason} ->
            {:drop, reason}

          # One prior successful run, reproducibility unconfirmed. If it
          # already mismatches this testcase's expecteds, drop with no run;
          # only if it matches do we pay to confirm determinism.
          {:single, c} ->
            if correct?(c, expecteds),
              do: confirm(source, sha, c, run_opts, run_count),
              else: {:drop, :mismatch}
        end

      :miss ->
        first_run(source, sha, expecteds, run_opts, run_count)
    end
  end

  defp keep_or_mismatch(c, expecteds),
    do: if(correct?(c, expecteds), do: {:keep, c}, else: {:drop, :mismatch})

  # Run ONCE and gate on error/timeout and correctness *before* paying for
  # the full N-run determinism check. A wrong answer (or error/timeout) is
  # dropped after a single run — only an output that already matches a
  # stored expected is worth confirming across the remaining runs. The
  # single run's output is cached (`:single`) so a re-encounter / resume
  # skips a known wrong answer with no python at all. This preserves which
  # pairs are kept (a reproducible-but-mismatching or nondeterministic
  # output was dropped under the old path too).
  defp first_run(source, sha, expecteds, run_opts, run_count) do
    case Execute.run_python(source, run_opts) do
      :timeout ->
        reject(sha, :timeout)

      :output_exceeded ->
        reject(sha, :output_exceeded)

      {:exit, _status, _out} ->
        reject(sha, :error)

      {:ok, out} ->
        canonical = Normalize.normalize(out)

        if correct?(canonical, expecteds) do
          confirm(source, sha, canonical, run_opts, run_count)
        else
          PythonCache.put(sha, encode_verdict({:single, canonical}))
          {:drop, :mismatch}
        end
    end
  end

  # Confirm determinism using `canonical` as run #1 plus `run_count - 1`
  # fresh runs; cache the upgraded verdict.
  defp confirm(source, sha, canonical, run_opts, run_count) do
    if reproduces?(source, run_opts, canonical, run_count - 1) do
      PythonCache.put(sha, encode_verdict({:reproducible, canonical}))
      {:keep, canonical}
    else
      PythonCache.put(sha, encode_verdict({:rejected, :nondeterministic}))
      {:drop, :nondeterministic}
    end
  end

  defp reject(sha, reason) do
    PythonCache.put(sha, encode_verdict({:rejected, reason}))
    {:drop, reason}
  end

  # The remaining `n` runs must all reproduce `canonical` exactly (any
  # later timeout/error/variation → not reproducible).
  defp reproduces?(_source, _run_opts, _canonical, 0), do: true

  defp reproduces?(source, run_opts, canonical, n) do
    case Execute.run_python(source, run_opts) do
      {:ok, out} -> Normalize.normalize(out) == canonical and reproduces?(source, run_opts, canonical, n - 1)
      _ -> false
    end
  end

  defp single_run_opts(opts, stdin, cap) do
    opts
    |> Keyword.take([:python])
    |> Keyword.merge(stdin: stdin, output_cap: cap, timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms))
  end

  @doc """
  The cached reproducibility verdict for `(source, stdin)`:
  `{:reproducible, canonical}` or `{:rejected, reason}` where reason ∈
  `:nondeterministic | :error | :timeout | :output_exceeded`.
  """
  @spec verdict(String.t(), String.t(), keyword()) :: verdict()
  def verdict(source, stdin, opts \\ []) do
    sha = PythonCache.key(source, stdin)

    case PythonCache.lookup(sha) do
      {:hit, entry} ->
        case decode_verdict(entry) do
          # `:single` is not a final verdict — recompute the full check.
          {:single, _} -> recompute_verdict(source, stdin, sha, opts)
          v -> v
        end

      :miss ->
        recompute_verdict(source, stdin, sha, opts)
    end
  end

  defp recompute_verdict(source, stdin, sha, opts) do
    v = compute_verdict(source, stdin, opts)
    PythonCache.put(sha, encode_verdict(v))
    v
  end

  # --- Internals -------------------------------------------------------

  defp compute_verdict(source, stdin, opts) do
    run_count = Keyword.get(opts, :run_count, @run_count)
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)

    run_opts =
      opts
      |> Keyword.take([:output_cap, :python])
      |> Keyword.merge(stdin: stdin, timeout_ms: timeout_ms)

    runs = for _ <- 1..run_count, do: Execute.run_python(source, run_opts)
    classify(runs)
  end

  # All runs must succeed (exit 0) and normalize to the same output.
  defp classify(runs) do
    cond do
      Enum.any?(runs, &(&1 == :timeout)) ->
        {:rejected, :timeout}

      Enum.any?(runs, &(&1 == :output_exceeded)) ->
        {:rejected, :output_exceeded}

      Enum.any?(runs, &match?({:exit, _, _}, &1)) ->
        {:rejected, :error}

      true ->
        normalized =
          runs
          |> Enum.map(fn {:ok, out} -> Normalize.normalize(out) end)
          |> Enum.uniq()

        case normalized do
          [canonical] -> {:reproducible, canonical}
          _ -> {:rejected, :nondeterministic}
        end
    end
  end

  defp correct?(canonical, expecteds) do
    Enum.any?(expecteds, &(Normalize.normalize(&1) == canonical))
  end

  defp output_cap(expecteds) do
    max_expected = expecteds |> Enum.map(&byte_size/1) |> Enum.max(fn -> 0 end)
    max_expected + @output_headroom
  end

  defp encode_verdict({:reproducible, canonical}),
    do: %{"status" => "reproducible", "canonical" => canonical}

  defp encode_verdict({:rejected, reason}),
    do: %{"status" => "rejected", "reason" => Atom.to_string(reason)}

  defp encode_verdict({:single, canonical}),
    do: %{"status" => "single", "canonical" => canonical}

  defp decode_verdict(%{"status" => "reproducible", "canonical" => canonical}),
    do: {:reproducible, canonical}

  defp decode_verdict(%{"status" => "rejected", "reason" => reason}),
    do: {:rejected, String.to_atom(reason)}

  defp decode_verdict(%{"status" => "single", "canonical" => canonical}),
    do: {:single, canonical}
end
