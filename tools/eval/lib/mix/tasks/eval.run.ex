defmodule Mix.Tasks.Eval.Run do
  @shortdoc "Run Pylixir against seed_sft + seed_testcase and write a report"

  @moduledoc """
  Build the joined `seed_sft` + `seed_testcase` corpus, run each
  passing solution against its full testcase set under CPython and
  Pylixir, classify per-testcase outcomes (4-way truth table) and roll
  up to a per-sample bucket, then write a report under
  `reports/run-<ISO8601>/`.

  ## Usage

      mix eval.run [--limit N] [--skip N] [--concurrency K]
                   [--samples-per-bucket K] [--save-ok N]
                   [--testcase-shards K]
                   [--python-timeout MS] [--elixir-timeout MS]
                   [--no-python-cache] [--rebuild-python-cache]
                   [--out DIR]

  ## Behavioral equivalence

  Each sample comes from `seed_sft` (Python solutions with
  `is_passed=True`) joined with its testcases from `seed_testcase` by
  `question_id`. For every `(source, stdin)` pair, the harness runs
  CPython (twice on first sight, for a determinism check) and caches
  the stdout in `cache/python.jsonl` (content-addressed by
  `sha256(source <> "\\0" <> stdin)`). Warm-cache runs skip CPython.

  The transpiled Elixir's `py_main/0` is then invoked with the same
  stdin and its stdout is compared:

    * Python ⟷ dataset `expected` — lenient (trailing-newline tolerant).
    * Elixir ⟷ Python — strict (byte-equal modulo CRLF).

  The per-testcase outcome lands in a 4-way classification (see
  `Eval.Bucket`); the sample's bucket is the worst-of across its
  testcase set.

  ## Examples

      # Smoke test on 5 samples
      mix eval.run --limit 5

      # Full pass with a custom concurrency cap
      mix eval.run --limit 10000 --concurrency 12

      # Load 3 seed_testcase shards (≈ 4.5 GB resident map)
      mix eval.run --limit 200 --testcase-shards 3

      # Skip the first 1000 samples (resume / jump ahead)
      mix eval.run --skip 1000 --limit 500

  ## Caching

  Parquet shards land in `cache/parquet/<config>/`. The joined corpus
  is memoised at `cache/corpus_v1.term.gz`; invalidated automatically
  if `--testcase-shards K` changes or any parquet shard is refreshed.

  Python preflight results are cached at `cache/python.jsonl`.
  `--no-python-cache` bypasses; `--rebuild-python-cache` truncates and
  rewrites.
  """

  use Mix.Task

  @switches [
    limit: :integer,
    skip: :integer,
    concurrency: :integer,
    samples_per_bucket: :integer,
    save_ok: :integer,
    testcase_shards: :integer,
    python_timeout: :integer,
    elixir_timeout: :integer,
    no_python_cache: :boolean,
    rebuild_python_cache: :boolean,
    no_examples: :boolean,
    max_examples: :integer,
    out: :string
  ]

  @default_python_timeout_ms 3_000
  @default_elixir_timeout_ms 5_000
  @default_testcase_shards 1

  @impl true
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    Mix.Task.run("app.start")

    # `ExUnit.CaptureIO` lives in `:ex_unit`. Starting the app does
    # NOT boot the test runner — `ExUnit.start/1` does. We only need
    # the module loadable from `Eval.Execute.run_elixir/3`.
    Application.ensure_all_started(:ex_unit)

    concurrency = opts[:concurrency] || System.schedulers_online() * 2

    # Suppress Python warnings (e.g. `SyntaxWarning: invalid escape
    # sequence`) from `Pylixir.python_ast/1`'s `python3` subprocess.
    # They leak through `System.cmd(..., stderr_to_stdout: false)` to
    # this task's terminal, can't be acted on, and aren't recorded in
    # the per-sample bucket — pure noise during a 10k-sample run.
    # `PYTHONWARNINGS` propagates to every child python process.
    System.put_env("PYTHONWARNINGS", "ignore")

    # CompilePool slot is held for compile + Σ(testcase Elixir runs) +
    # purge. Sizing to `concurrency` keeps Task.async_stream workers
    # from blocking on slot checkout.
    Eval.CompilePool.ensure_started(size: concurrency)

    Eval.PythonCache.ensure_started(
      path: default_python_cache_path(),
      no_cache: opts[:no_python_cache] || false,
      rebuild: opts[:rebuild_python_cache] || false
    )

    Eval.TraceCache.ensure_started(
      path: default_trace_cache_path(),
      no_cache: opts[:no_python_cache] || false
    )

    eval_opts = [
      limit: opts[:limit],
      skip: opts[:skip],
      concurrency: concurrency,
      samples_per_bucket: opts[:samples_per_bucket],
      save_ok: opts[:save_ok],
      testcase_shards: opts[:testcase_shards] || @default_testcase_shards,
      python_timeout_ms: opts[:python_timeout] || @default_python_timeout_ms,
      elixir_timeout_ms: opts[:elixir_timeout] || @default_elixir_timeout_ms,
      no_examples: opts[:no_examples] || false,
      max_examples: opts[:max_examples] || 3
    ]

    progress = start_progress(opts[:limit])
    eval_opts = Keyword.put(eval_opts, :on_sample, fn _record -> tick(progress) end)

    accumulator = Eval.run(eval_opts)

    run_dir = Eval.Report.write(accumulator, out: opts[:out], comparison_mode: :executed)

    IO.puts("")
    IO.puts("report: #{run_dir}")
    IO.puts("elapsed: #{format_elapsed(elapsed_ms(progress))}")
    print_top_buckets(accumulator)
  end

  defp default_python_cache_path,
    do: Path.join([File.cwd!(), "cache", "python.jsonl"])

  defp default_trace_cache_path,
    do: Path.join([File.cwd!(), "cache", "python_traces.jsonl"])

  defp start_progress(limit) do
    ref = :counters.new(1, [:atomics])
    {ref, limit, System.monotonic_time(:millisecond)}
  end

  defp tick({ref, limit, _start}) do
    :counters.add(ref, 1, 1)
    n = :counters.get(ref, 1)

    cond do
      rem(n, 25) == 0 and limit -> IO.write("\rprocessed: #{n}/#{limit}")
      rem(n, 25) == 0 -> IO.write("\rprocessed: #{n}")
      true -> :ok
    end
  end

  defp elapsed_ms({_ref, _limit, start}),
    do: System.monotonic_time(:millisecond) - start

  # Format an elapsed-ms count as `Xm Ys` for runs ≥ 1 minute, `Y.Zs`
  # for shorter runs. Sub-minute fractional precision helps when
  # iterating on small `--limit` smoke tests; rounded seconds are
  # plenty for the 10k-sample full-run case.
  defp format_elapsed(ms) when ms < 60_000,
    do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)}s"

  defp format_elapsed(ms) do
    total_s = div(ms, 1000)
    "#{div(total_s, 60)}m #{rem(total_s, 60)}s"
  end

  defp print_top_buckets(%{counts: counts}) when map_size(counts) == 0 do
    IO.puts("no samples processed")
  end

  defp print_top_buckets(%{counts: counts, totals: totals} = acc) do
    IO.puts("\n--- top buckets ---")

    tc_counts = Map.get(acc, :testcase_counts, %{})

    IO.puts(
      "  #{String.pad_trailing("bucket", 50)} #{String.pad_leading("samples", 8)}  share   testcases (pass/run)"
    )

    counts
    |> Enum.sort_by(fn {_k, n} -> -n end)
    |> Enum.take(10)
    |> Enum.each(fn {key, n} ->
      slug = Eval.Bucket.slug(key)

      share =
        if totals.processed > 0,
          do: :erlang.float_to_binary(n / totals.processed * 100, decimals: 1),
          else: "0.0"

      %{run: tc_run, passed: tc_passed} = Map.get(tc_counts, key, %{run: 0, passed: 0})

      tc_summary =
        if tc_run == 0,
          do: "—",
          else: "#{tc_passed}/#{tc_run}"

      IO.puts(
        "  #{String.pad_trailing(slug, 50)} #{String.pad_leading(Integer.to_string(n), 8)}  #{String.pad_leading(share <> "%", 5)}   #{tc_summary}"
      )
    end)

    IO.puts(
      "  #{String.pad_trailing("TOTAL", 50)} #{String.pad_leading(Integer.to_string(totals.processed), 8)}          #{totals.testcases_passed}/#{totals.testcases_run}"
    )
  end
end
