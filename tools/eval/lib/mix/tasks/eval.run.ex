defmodule Mix.Tasks.Eval.Run do
  @shortdoc "Run Pylixir against a streamed HF dataset and write a report"

  @moduledoc """
  Stream a Hugging Face dataset through Pylixir, classify failures, and
  write a report under `reports/run-<ISO8601>/`.

  ## Usage

      mix eval.run [--limit N] [--skip N] [--concurrency K]
                   [--samples-per-bucket K] [--dataset NAME] [--split SPLIT]
                   [--field NAME] [--name CONFIG] [--cache PATH] [--no-cache]
                   [--out DIR]

  ## Examples

      # Smoke test on 5 samples
      mix eval.run --limit 5

      # Full pass with a custom concurrency cap
      mix eval.run --limit 10000 --concurrency 12

      # Different dataset
      mix eval.run --dataset codeparrot/apps --split test --limit 200

      # Skip the first 1000 samples (resume / jump ahead)
      mix eval.run --skip 1000 --limit 500 --name synthetic_sft

  ## Caching

  By default, samples are cached to
  `cache/<dataset-slug>--<name>--<split>.jsonl` under tools/eval/.
  First run streams from HF and writes the cache; subsequent runs
  serve from the cache (no HF download). Pass `--cache PATH` to use
  a specific cache file, or `--no-cache` to bypass entirely.
  """

  use Mix.Task

  @switches [
    limit: :integer,
    skip: :integer,
    concurrency: :integer,
    samples_per_bucket: :integer,
    dataset: :string,
    split: :string,
    field: :string,
    name: :string,
    cache: :string,
    no_cache: :boolean,
    out: :string
  ]

  @impl true
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    Mix.Task.run("app.start")

    eval_opts =
      opts
      |> Keyword.put(:offset, opts[:skip])
      |> Keyword.delete(:skip)
      |> apply_cache_default()

    progress = start_progress(opts[:limit])
    eval_opts = Keyword.put(eval_opts, :on_sample, fn _line -> tick(progress) end)

    accumulator = Eval.run(eval_opts)
    run_dir = Eval.Report.write(accumulator, out: opts[:out])

    IO.puts("")
    IO.puts("report: #{run_dir}")
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
