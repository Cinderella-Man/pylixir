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

  ## Options
    * `:run_count` (default #{@run_count})
    * `:timeout_ms` (default #{@timeout_ms})
    * `:python`
  """
  @spec verify_solution(%{source: String.t()}, [map()], keyword()) :: [map()]
  def verify_solution(%{source: source}, testcases, opts \\ []) do
    testcases
    |> Enum.flat_map(fn tc ->
      case verify_testcase(source, tc, opts) do
        {:keep, canonical} ->
          [%{stdin: tc.stdin, expected: canonical, n_stored_outputs: tc.n_stored_outputs}]

        {:drop, _reason} ->
          []
      end
    end)
  end

  @doc """
  Verify a single `(source, testcase)`. Returns `{:keep, canonical}` or
  `{:drop, reason}`.
  """
  @spec verify_testcase(String.t(), map(), keyword()) ::
          {:keep, String.t()} | {:drop, atom()}
  def verify_testcase(source, %{stdin: stdin, expecteds: expecteds}, opts \\ []) do
    cap = output_cap(expecteds)

    case verdict(source, stdin, Keyword.put(opts, :output_cap, cap)) do
      {:reproducible, canonical} ->
        if correct?(canonical, expecteds), do: {:keep, canonical}, else: {:drop, :mismatch}

      {:rejected, reason} ->
        {:drop, reason}
    end
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
        decode_verdict(entry)

      :miss ->
        v = compute_verdict(source, stdin, opts)
        PythonCache.put(sha, encode_verdict(v))
        v
    end
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

  defp decode_verdict(%{"status" => "reproducible", "canonical" => canonical}),
    do: {:reproducible, canonical}

  defp decode_verdict(%{"status" => "rejected", "reason" => reason}),
    do: {:rejected, String.to_atom(reason)}
end
