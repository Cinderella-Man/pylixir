defmodule Mix.Tasks.Eval.Run do
  @shortdoc "Run Pylixir against a streamed HF dataset and write a report"

  @moduledoc """
  Stream a Hugging Face dataset through Pylixir, classify failures, and
  write a report under `reports/run-<ISO8601>/`.

  ## Usage

      mix eval.run [--limit N] [--concurrency K] [--samples-per-bucket K]
                   [--dataset NAME] [--split SPLIT] [--field NAME]
                   [--name CONFIG] [--out DIR]

  ## Examples

      # Smoke test on 5 samples
      mix eval.run --limit 5

      # Full pass with a custom concurrency cap
      mix eval.run --limit 10000 --concurrency 12

      # Different dataset
      mix eval.run --dataset codeparrot/apps --split test --limit 200
  """

  use Mix.Task

  @switches [
    limit: :integer,
    concurrency: :integer,
    samples_per_bucket: :integer,
    dataset: :string,
    split: :string,
    field: :string,
    name: :string,
    out: :string
  ]

  @impl true
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    Mix.Task.run("app.start")

    progress = start_progress(opts[:limit])
    eval_opts = Keyword.put(opts, :on_sample, fn _line -> tick(progress) end)

    accumulator = Eval.run(eval_opts)
    run_dir = Eval.Report.write(accumulator, out: opts[:out])

    IO.puts("")
    IO.puts("report: #{run_dir}")
    print_top_buckets(accumulator)
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
