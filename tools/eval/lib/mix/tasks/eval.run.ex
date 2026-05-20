defmodule Mix.Tasks.Eval.Run do
  @shortdoc "Run Pylixir against a streamed HF dataset and write a report"

  @moduledoc """
  Stream a Hugging Face dataset through Pylixir, classify failures, and
  write a report under `reports/run-<ISO8601>/`.

  ## Usage

      mix eval.run [--limit N] [--skip N] [--concurrency K]
                   [--samples-per-bucket K] [--dataset NAME] [--split SPLIT]
                   [--field NAME] [--name CONFIG] [--cache PATH] [--no-cache]
                   [--execute|--no-execute]
                   [--python-timeout MS] [--elixir-timeout MS]
                   [--no-python-cache] [--rebuild-python-cache]
                   [--out DIR]

  ## Behavioral equivalence

  By default the harness runs each Python sample through CPython
  (twice, for a determinism check) and compares its stdout to the
  transpiled Elixir's stdout byte-equal. Python results are cached
  in `cache/python.jsonl` (content-addressed by source SHA-256), so
  warm-cache runs skip the CPython step entirely.

  Pass `--no-execute` to keep the v1 behavior (transpile + compile
  only, no Python or Elixir execution).

  ## Examples

      # Smoke test on 5 samples
      mix eval.run --limit 5

      # Full pass with a custom concurrency cap
      mix eval.run --limit 10000 --concurrency 12

      # Different dataset
      mix eval.run --dataset codeparrot/apps --split test --limit 200

      # Skip the first 1000 samples (resume / jump ahead)
      mix eval.run --skip 1000 --limit 500 --name synthetic_sft

      # Compile-only (no execution; matches v1 semantics)
      mix eval.run --limit 100 --no-execute

  ## Caching

  By default, samples are cached to
  `cache/<dataset-slug>--<name>--<split>.jsonl` under tools/eval/.
  First run streams from HF and writes the cache; subsequent runs
  serve from the cache (no HF download). Pass `--cache PATH` to use
  a specific cache file, or `--no-cache` to bypass entirely.

  Python preflight results are independently cached at
  `cache/python.jsonl`. `--no-python-cache` bypasses;
  `--rebuild-python-cache` truncates and rewrites.
  """

  use Mix.Task

  @switches [
    limit: :integer,
    skip: :integer,
    concurrency: :integer,
    samples_per_bucket: :integer,
    save_ok: :integer,
    dataset: :string,
    split: :string,
    field: :string,
    name: :string,
    cache: :string,
    no_cache: :boolean,
    execute: :boolean,
    python_timeout: :integer,
    elixir_timeout: :integer,
    no_python_cache: :boolean,
    rebuild_python_cache: :boolean,
    out: :string
  ]

  @default_python_timeout_ms 3_000
  @default_elixir_timeout_ms 5_000

  @impl true
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    Mix.Task.run("app.start")

    # `ExUnit.CaptureIO` lives in `:ex_unit`. Starting the app does
    # NOT boot the test runner — `ExUnit.start/1` does. We only need
    # the module loadable from `Eval.Execute.run_elixir/2`.
    Application.ensure_all_started(:ex_unit)

    # OptionParser with `execute: :boolean` accepts both `--execute`
    # (→ true) and `--no-execute` (→ false). Default: ON.
    execute? = Keyword.get(opts, :execute, true)
    concurrency = opts[:concurrency] || System.schedulers_online() * 2

    # Suppress Python warnings (e.g. `SyntaxWarning: invalid escape
    # sequence`) from `Pylixir.python_ast/1`'s `python3` subprocess.
    # They leak through `System.cmd(..., stderr_to_stdout: false)` to
    # this task's terminal, can't be acted on, and aren't recorded in
    # the per-sample bucket — pure noise during a 10k-sample run.
    # `PYTHONWARNINGS` propagates to every child python process.
    System.put_env("PYTHONWARNINGS", "ignore")

    # CompilePool slot is held for compile + (when executing) py_main
    # invocation. Sizing to `concurrency` keeps Task.async_stream
    # workers from blocking on slot checkout.
    Eval.CompilePool.ensure_started(size: concurrency)

    if execute? do
      Eval.PythonCache.ensure_started(
        path: default_python_cache_path(),
        no_cache: opts[:no_python_cache] || false,
        rebuild: opts[:rebuild_python_cache] || false
      )
    end

    eval_opts =
      opts
      |> Keyword.put(:offset, opts[:skip])
      |> Keyword.delete(:skip)
      |> Keyword.put(:execute, execute?)
      |> Keyword.put(:concurrency, concurrency)
      |> Keyword.put(
        :python_timeout_ms,
        opts[:python_timeout] || @default_python_timeout_ms
      )
      |> Keyword.put(
        :elixir_timeout_ms,
        opts[:elixir_timeout] || @default_elixir_timeout_ms
      )
      |> Keyword.delete(:python_timeout)
      |> Keyword.delete(:elixir_timeout)
      |> Keyword.delete(:no_python_cache)
      |> Keyword.delete(:rebuild_python_cache)
      |> apply_cache_default()

    progress = start_progress(opts[:limit])
    eval_opts = Keyword.put(eval_opts, :on_sample, fn _line -> tick(progress) end)

    accumulator = Eval.run(eval_opts)

    comparison_mode = if execute?, do: :executed, else: :compile_only
    run_dir = Eval.Report.write(accumulator, out: opts[:out], comparison_mode: comparison_mode)

    IO.puts("")
    IO.puts("report: #{run_dir}")
    IO.puts("elapsed: #{format_elapsed(elapsed_ms(progress))}")
    print_top_buckets(accumulator)
  end

  # Default cache path is auto-derived from (dataset, name, split) so
  # repeated runs against the same slice hit the local file. Explicit
  # --cache PATH overrides; --no-cache disables caching entirely.
  defp apply_cache_default(opts) do
    cond do
      Keyword.get(opts, :no_cache) ->
        Keyword.delete(opts, :cache)

      opts[:cache] ->
        opts

      true ->
        path = default_cache_path(opts)
        Keyword.put(opts, :cache, path)
    end
    |> Keyword.delete(:no_cache)
  end

  defp default_cache_path(opts) do
    dataset = opts[:dataset] || "microsoft/rStar-Coder"
    name = opts[:name] || "default"
    split = opts[:split] || "train"

    slug =
      [dataset, name, split]
      |> Enum.map_join("--", &String.replace(&1, ~r/[^A-Za-z0-9._-]+/, "_"))

    Path.join([File.cwd!(), "cache", slug <> ".jsonl"])
  end

  defp default_python_cache_path,
    do: Path.join([File.cwd!(), "cache", "python.jsonl"])

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

  defp print_top_buckets(%{counts: counts, totals: totals}) do
    IO.puts("\n--- top buckets ---")

    counts
    |> Enum.sort_by(fn {_k, n} -> -n end)
    |> Enum.take(10)
    |> Enum.each(fn {key, n} ->
      slug = Eval.Bucket.slug(key)

      share =
        if totals.processed > 0,
          do: :erlang.float_to_binary(n / totals.processed * 100, decimals: 1),
          else: "0.0"

      IO.puts(
        "  #{String.pad_trailing(slug, 50)} #{String.pad_leading(Integer.to_string(n), 6)}  #{share}%"
      )
    end)
  end
end
