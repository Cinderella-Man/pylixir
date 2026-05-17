defmodule Eval do
  @moduledoc """
  Orchestrates the dataset evaluation pipeline:

      Eval.Stream.stream/1
        ↳ Task.async_stream(&attempt/1)
            ↳ Eval.Bucket.classify/2
                ↳ accumulator that holds counts + first K samples per bucket

  `run/1` returns the accumulator. `Eval.Report.write/2` consumes it.
  """

  alias Eval.{Bucket, Compile}

  @type accumulator :: %{
          counts: %{Bucket.bucket_key() => non_neg_integer()},
          samples: %{Bucket.bucket_key() => [sample_entry()]},
          totals: %{
            processed: non_neg_integer(),
            skipped: non_neg_integer(),
            transpiled: non_neg_integer()
          }
        }

  @type sample_entry :: %{id: String.t(), source: String.t(), metadata: map()}

  @type opts :: [
          {:limit, pos_integer()}
          | {:concurrency, pos_integer()}
          | {:samples_per_bucket, pos_integer()}
          | {:dataset, String.t()}
          | {:split, String.t()}
          | {:field, String.t()}
          | {:name, String.t()}
          | {:on_sample, (map() -> any())}
        ]

  @default_concurrency_multiplier 2
  @default_samples_per_bucket 10

  @spec run(opts()) :: accumulator()
  def run(opts \\ []) do
    stream_opts = Keyword.take(opts, [:limit, :offset, :dataset, :split, :field, :name, :cache])
    enumerable = opts[:samples] || Eval.Stream.stream(stream_opts)
    process(enumerable, opts)
  end

  @doc """
  Run the classification pipeline against any enumerable of decoded
  Python-side lines (`%{"id" => _, "source" => _}` or `%{"_skip" => _}`).

  Exposed so tests can drive the harness without booting the real
  dataset stream.
  """
  @spec process(Enumerable.t(), opts()) :: accumulator()
  def process(enumerable, opts \\ []) do
    concurrency =
      opts[:concurrency] || System.schedulers_online() * @default_concurrency_multiplier

    samples_per_bucket = opts[:samples_per_bucket] || @default_samples_per_bucket
    on_sample = opts[:on_sample] || fn _ -> :ok end

    initial = %{
      counts: %{},
      samples: %{},
      totals: %{processed: 0, skipped: 0, transpiled: 0}
    }

    enumerable
    |> Stream.each(on_sample)
    |> Task.async_stream(
      fn line ->
        case line do
          %{"_skip" => _} = skip -> {:skip, skip}
          %{"id" => id, "source" => source} -> attempt(%{id: id, source: source})
        end
      end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(initial, fn
      {:ok, {:skip, _}}, acc ->
        update_in(acc.totals.skipped, &(&1 + 1))

      {:ok, {sample, bucket_key, metadata}}, acc ->
        acc
        |> update_in([:totals, :processed], &(&1 + 1))
        |> maybe_count_transpiled(bucket_key)
        |> bump_count(bucket_key)
        |> maybe_store_sample(bucket_key, sample, metadata, samples_per_bucket)

      {:exit, reason}, acc ->
        IO.warn("worker task exited: #{inspect(reason)}")
        acc
    end)
  end

  @spec attempt(Bucket.sample()) :: {Bucket.sample(), Bucket.bucket_key(), map()}
  def attempt(%{source: source} = sample) do
    outcome =
      try do
        elixir_source = Pylixir.transpile(source)

        case Compile.check(elixir_source) do
          {:ok, diagnostics} ->
            {:transpile_ok, elixir_source, {:compile_ok, diagnostics}}

          {:error, exception} ->
            {:transpile_ok, elixir_source, {:compile_raised, exception}}
        end
      rescue
        e -> {:transpile_raised, e}
      end

    {bucket, metadata} = Bucket.classify(sample, outcome)
    {sample, bucket, metadata}
  end

  defp bump_count(acc, key),
    do: update_in(acc.counts[key], fn n -> (n || 0) + 1 end)

  defp maybe_count_transpiled(acc, :ok),
    do: update_in(acc.totals.transpiled, &(&1 + 1))

  defp maybe_count_transpiled(acc, _other), do: acc

  defp maybe_store_sample(acc, key, sample, metadata, cap) do
    existing = Map.get(acc.samples, key, [])

    if length(existing) >= cap do
      acc
    else
      entry = %{id: sample.id, source: sample.source, metadata: metadata}
      put_in(acc.samples[key], existing ++ [entry])
    end
  end
end
