defmodule Dataset.Behavioral do
  @moduledoc """
  Behavioral-equivalence dedup signal (the gold standard). Two shipped
  rows are the **same problem** if each one's chosen solution reproduces
  **all** of the other's testcases — i.e. the solutions are
  interchangeable on both testcase sets. This catches duplicates no
  structural signal can: same problem with a *genuinely different*
  solution, and cosmetic solution variants (operator associativity, set
  literal order, dead imports) that escape the AST hash.

  Equivalence is **bidirectional and exact**: `A` must reproduce every one
  of `B`'s testcases *and* `B` every one of `A`'s. Verdicts come from
  `Dataset.Verify.verdict/3`, so each `(source, stdin)` is run under the
  sandbox `run_count` times for determinism and the result is cached
  (`Dataset.PythonCache`) — cross-checks populate the cache and the whole
  pass is resumable.

  Cost is controlled upstream: the caller only passes **candidate** pairs
  (`Dataset.Dedup.candidates/2` — gated by seed-adjacency and shared
  testcases), and each check **short-circuits** at the first testcase a
  solution fails (the common case), so non-duplicates are cheap.
  """

  alias Dataset.Verify
  require Logger

  # Headroom over the compared `expected` for the per-testcase output cap
  # (mirrors Dataset.Verify's @output_headroom). Any stdout larger than the
  # expected output is already a mismatch, so capping here is semantically
  # free — and it stops a solution that loops/prints unboundedly on a
  # *foreign* stdin from accumulating GBs of output in memory (the source of
  # the behavioral-stage OOM and the multi-GB cache entries that bloat it).
  @output_headroom 1024 * 1024

  @doc """
  Behavioral edges among `pairs` (`[{id_a, id_b}]`), computed concurrently.
  `rows_by_id` maps id → `%{source, testcases}` (testcases as shipped:
  `%{stdin, expected, ...}`). Returns the equivalent pairs.

  ## Options
    * `:concurrency` (default `schedulers_online`)
    * `:run_count`, `:timeout_ms`, `:python` — forwarded to `Verify.verdict/3`.
    * `:verdict_fun` — `(source, stdin, opts -> verdict)`; default
      `&Dataset.Verify.verdict/3` (overridable for tests).
  """
  @spec edges(%{String.t() => map()}, [{String.t(), String.t()}], keyword()) ::
          [{String.t(), String.t()}]
  def edges(rows_by_id, pairs, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    # Progress can be driven across many byte-budget chunks (see
    # `Dataset.Build`): when the caller passes a shared `:counter` and `:total`,
    # we report *global* progress and skip the per-chunk header. Called
    # standalone (e.g. tests), it self-counts and logs its own header.
    total = Keyword.get(opts, :total, length(pairs))
    counter = Keyword.get_lazy(opts, :counter, fn -> :counters.new(1, [:atomics]) end)

    unless Keyword.has_key?(opts, :counter) do
      Logger.info("[behavioral] checking #{total} candidate pairs (concurrency #{concurrency})")
    end

    pairs
    |> Task.async_stream(
      fn {a, b} ->
        result =
          if equivalent?(Map.fetch!(rows_by_id, a), Map.fetch!(rows_by_id, b), opts),
            do: {a, b},
            else: nil

        n = :counters.add(counter, 1, 1) && :counters.get(counter, 1)
        if rem(n, 250) == 0 or n == total, do: Logger.info("[behavioral] #{n}/#{total} pairs")
        result
      end,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, pair} -> [pair]
    end)
  end

  @doc """
  True iff each row's solution reproduces **all** of the other's
  testcases. Short-circuits at the first failure.
  """
  @spec equivalent?(map(), map(), keyword()) :: boolean()
  def equivalent?(a, b, opts \\ []) do
    verdict_fun = Keyword.get(opts, :verdict_fun, &Verify.verdict/3)
    run_opts = Keyword.take(opts, [:run_count, :timeout_ms, :python])

    reproduces_all?(verdict_fun, a.source, b.testcases, run_opts) and
      reproduces_all?(verdict_fun, b.source, a.testcases, run_opts)
  end

  # `source` must deterministically reproduce every testcase's shipped
  # `expected` (already the normalized canonical, comparable to the
  # verdict's canonical). Stops at the first miss.
  defp reproduces_all?(verdict_fun, source, testcases, run_opts) do
    Enum.all?(testcases, fn tc ->
      # Cap stdout at the compared expected (+ headroom): a larger output can
      # never match, so the cap only kills runaway producers, never a real
      # reproduction. Without it a foreign stdin can drive unbounded output.
      opts = Keyword.put(run_opts, :output_cap, byte_size(tc.expected) + @output_headroom)

      case verdict_fun.(source, tc.stdin, opts) do
        {:reproducible, canonical} -> canonical == tc.expected
        _ -> false
      end
    end)
  end
end
