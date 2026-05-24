defmodule Mix.Tasks.Eval.Run do
  @shortdoc "Run Pylixir against the curated dataset and write a report"

  @moduledoc """
  Stream the curated `data.parquet` corpus (see `Eval.Dataset` /
  `Eval.Corpus`), transpile each solution to Elixir, run it per testcase,
  classify each per-testcase outcome (2-way: Elixir stdout vs the
  dataset's verified `expected`) and roll up to a per-sample bucket, then
  write a report under `reports/run-<ISO8601>/`.

  ## Usage

      mix eval.run [--limit N] [--skip N] [--concurrency K]
                   [--samples-per-bucket K] [--save-ok N]
                   [--python-timeout MS] [--elixir-timeout MS]
                   [--no-examples] [--max-examples N]
                   [--out DIR]

  ## Behaviour

  Each sample is a row of the curated dataset: a Python `source` and its
  `testcases` (`stdin` + the verified, normalized `expected`). The
  transpiled Elixir's `py_main/0` is invoked with each `stdin` and its
  stdout is compared to `expected` under the canonical normalizer
  (`Eval.Execute.compare/2`); a mismatch is an `:output_mismatch` (a
  Pylixir bug). The sample's bucket is the worst-of across its testcases
  (see `Eval.Bucket`).

  CPython is invoked only to capture trace envelopes for example-guided
  transpilation, cached in `cache/python_traces.jsonl` (`Eval.TraceCache`);
  `--python-timeout` is that tracer's wall-clock budget.

  ## Examples

      mix eval.run --limit 5                 # smoke test
      mix eval.run --limit 10000 --concurrency 12
      mix eval.run --skip 1000 --limit 500   # resume / jump ahead

  ## Caching

  The dataset is downloaded once to `cache/data.parquet` (delete it to
  refresh). Tracer envelopes are cached at `cache/python_traces.jsonl`.
  """

  use Mix.Task

  @switches [
    limit: :integer,
    skip: :integer,
    concurrency: :integer,
    samples_per_bucket: :integer,
    save_ok: :integer,
    python_timeout: :integer,
    elixir_timeout: :integer,
    no_examples: :boolean,
    max_examples: :integer,
    out: :string
  ]

  @default_python_timeout_ms 10_000
  @default_elixir_timeout_ms 10_000

  @impl true
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    Mix.Task.run("app.start")

    # `ExUnit.CaptureIO` lives in `:ex_unit`; we need the module loadable
    # from `Eval.Execute.run_elixir/3`.
    Application.ensure_all_started(:ex_unit)

    concurrency = opts[:concurrency] || System.schedulers_online() * 2

    # Suppress Python warnings from the tracer's `python3` subprocess —
    # pure noise during a large run.
    System.put_env("PYTHONWARNINGS", "ignore")

    # CompilePool slot is held for compile + Σ(testcase Elixir runs) +
    # purge. Sizing to `concurrency` keeps workers from blocking on slot
    # checkout.
    Eval.CompilePool.ensure_started(size: concurrency)

    Eval.TraceCache.ensure_started(
      path: default_trace_cache_path(),
      no_cache: opts[:no_examples] || false
    )

    eval_opts = [
      limit: opts[:limit],
      skip: opts[:skip],
      concurrency: concurrency,
      samples_per_bucket: opts[:samples_per_bucket],
      save_ok: opts[:save_ok],
      python_timeout_ms: opts[:python_timeout] || @default_python_timeout_ms,
      elixir_timeout_ms: opts[:elixir_timeout] || @default_elixir_timeout_ms,
      no_examples: opts[:no_examples] || false,
      max_examples: opts[:max_examples] || 3
    ]

    progress = start_progress(opts[:limit])
    eval_opts = Keyword.put(eval_opts, :on_sample, fn _record -> tick(progress) end)

    accumulator = Eval.run(eval_opts)

    run_dir = Eval.Report.write(accumulator, out: opts[:out])

    IO.puts("")
    IO.puts("report: #{run_dir}")
    IO.puts("elapsed: #{format_elapsed(elapsed_ms(progress))}")
    print_top_buckets(accumulator)
  end

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

      tc_summary = if tc_run == 0, do: "—", else: "#{tc_passed}/#{tc_run}"

      IO.puts(
        "  #{String.pad_trailing(slug, 50)} #{String.pad_leading(Integer.to_string(n), 8)}  #{String.pad_leading(share <> "%", 5)}   #{tc_summary}"
      )
    end)

    IO.puts(
      "  #{String.pad_trailing("TOTAL", 50)} #{String.pad_leading(Integer.to_string(totals.processed), 8)}          #{totals.testcases_passed}/#{totals.testcases_run}"
    )
  end
end
