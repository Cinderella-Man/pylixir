defmodule Eval do
  @moduledoc """
  Orchestrates the dataset evaluation pipeline:

      Eval.Corpus.build/1                          # curated data.parquet stream
        ↳ Task.async_stream(&attempt/2)
            ↳ Pylixir.transpile  →  Compile.check_and_execute_testcases
                ↳ per testcase: Elixir run + 2-way classify vs `expected`
            ↳ Eval.Bucket.classify/2 (worst-of rollup)
                ↳ accumulator that holds counts + first K samples per bucket

  `run/1` returns the accumulator. `Eval.Report.write/2` consumes it.

  ## Per-testcase semantics

  Each sample carries a list of `%{stdin, expected}` testcases. `expected`
  is the dataset's **verified, deterministic, normalized CPython output**,
  so there is no Python to run for ground truth — we compare the Elixir
  `py_main/0` stdout directly against `expected` under the canonical
  normalizer (`Eval.Execute.compare/2`):

    * equal → `:ok` / `:ok_empty`
    * differ → `:output_mismatch` (a Pylixir bug)

  CPython is still invoked once per example (cached in `Eval.TraceCache`)
  to capture the trace envelope that guides `Pylixir.transpile/2`.

  Per-sample bucket is the worst-of across all testcases. See
  `Eval.Bucket` for the severity ladder and bucket keys.
  """

  alias Eval.{Bucket, Compile, Corpus, Execute, TraceCache}

  @type accumulator :: %{
          counts: %{Bucket.bucket_key() => non_neg_integer()},
          testcase_counts: %{
            Bucket.bucket_key() => %{run: non_neg_integer(), passed: non_neg_integer()}
          },
          samples: %{Bucket.bucket_key() => [sample_entry()]},
          totals: %{
            processed: non_neg_integer(),
            transpiled: non_neg_integer(),
            testcases_run: non_neg_integer(),
            testcases_passed: non_neg_integer()
          }
        }

  @type sample_entry :: %{id: String.t(), source: String.t(), metadata: map()}

  @type opts :: [
          {:limit, pos_integer()}
          | {:skip, non_neg_integer()}
          | {:concurrency, pos_integer()}
          | {:samples_per_bucket, pos_integer()}
          | {:save_ok, non_neg_integer()}
          | {:python_timeout_ms, pos_integer()}
          | {:elixir_timeout_ms, pos_integer()}
          | {:on_sample, (map() -> any())}
          | {:samples, Enumerable.t()}
          | {:no_examples, boolean()}
          | {:max_examples, pos_integer()}
        ]

  # See the original note: 1× schedulers keeps each fed without
  # oversubscription; eval runs take ~2× wall time, acceptable here.
  @default_concurrency_multiplier 1
  @default_samples_per_bucket 10
  # The tracer (example inference) budget — CPython's only remaining role.
  @default_python_timeout_ms 10_000
  @default_elixir_timeout_ms 30_000

  @spec run(opts()) :: accumulator()
  def run(opts \\ []) do
    enumerable =
      case Keyword.fetch(opts, :samples) do
        {:ok, samples} -> samples
        :error -> Corpus.build()
      end

    enumerable
    |> apply_limit_skip(opts)
    |> process(opts)
  end

  @doc """
  Run the classification pipeline against any enumerable of corpus
  records (`%{id: _, source: _, testcases: _}`). Exposed so tests can
  drive the harness without booting the real corpus.
  """
  @spec process(Enumerable.t(), opts()) :: accumulator()
  def process(enumerable, opts \\ []) do
    concurrency =
      opts[:concurrency] || System.schedulers_online() * @default_concurrency_multiplier

    samples_per_bucket = opts[:samples_per_bucket] || @default_samples_per_bucket
    # `--save-ok N` overrides the cap *only for the :ok bucket*.
    save_ok = opts[:save_ok] || 0
    on_sample = opts[:on_sample] || fn _ -> :ok end
    python_timeout = opts[:python_timeout_ms] || @default_python_timeout_ms
    elixir_timeout = opts[:elixir_timeout_ms] || @default_elixir_timeout_ms

    attempt_opts = [
      python_timeout_ms: python_timeout,
      elixir_timeout_ms: elixir_timeout,
      no_examples: Keyword.get(opts, :no_examples, false),
      max_examples: Keyword.get(opts, :max_examples, 3)
    ]

    initial = %{
      counts: %{},
      testcase_counts: %{},
      samples: %{},
      totals: %{
        processed: 0,
        transpiled: 0,
        testcases_run: 0,
        testcases_passed: 0
      }
    }

    enumerable
    |> Task.async_stream(
      fn record -> attempt(record, attempt_opts) end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.each(on_sample)
    |> Enum.reduce(initial, fn
      {:ok, {sample, bucket_key, metadata}}, acc ->
        cap = if bucket_key == :ok, do: save_ok, else: samples_per_bucket
        per_tc = Map.get(metadata, :per_testcase, [])
        tc_run = length(per_tc)
        tc_passed = count_passed(per_tc)

        acc
        |> update_in([:totals, :processed], &(&1 + 1))
        |> update_in([:totals, :testcases_run], &(&1 + tc_run))
        |> update_in([:totals, :testcases_passed], &(&1 + tc_passed))
        |> bump_testcase_counts(bucket_key, tc_run, tc_passed)
        |> maybe_count_transpiled(bucket_key)
        |> bump_count(bucket_key)
        |> maybe_store_sample(bucket_key, sample, metadata, cap)

      {:exit, reason}, acc ->
        IO.warn("worker task exited: #{inspect(reason)}")
        acc
    end)
  end

  @spec attempt(map(), keyword()) ::
          {Bucket.sample(), Bucket.bucket_key(), map()}
  def attempt(%{id: id, source: source, testcases: testcases}, opts) do
    sample = %{id: id, source: source}
    outcome = run_attempt(source, testcases, opts)
    {bucket, metadata} = Bucket.classify(sample, outcome)
    {sample, bucket, metadata}
  end

  defp run_attempt(source, testcases, opts) do
    elixir_timeout = Keyword.fetch!(opts, :elixir_timeout_ms)
    trace_timeout = Keyword.fetch!(opts, :python_timeout_ms)
    no_examples = Keyword.get(opts, :no_examples, false)
    max_examples = Keyword.get(opts, :max_examples, 3)

    # Pre-warm the trace cache so the library's transpile call can read
    # trace_events from the cache instead of re-running the tracer per
    # example.
    unless no_examples do
      testcases
      |> Enum.take(max_examples)
      |> Enum.each(fn %{stdin: stdin} -> prewarm_trace(source, stdin, trace_timeout) end)
    end

    examples = examples_from_testcases(source, testcases, opts)

    try do
      elixir_source = Pylixir.transpile(source, examples: examples)

      result =
        Compile.check_and_execute_testcases(
          elixir_source,
          testcases,
          elixir_timeout,
          fn module, tc -> testcase_outcome(module, tc, elixir_timeout) end
        )

      case result do
        {:executed_testcases, _diagnostics, _per_tc} = ok ->
          {:transpile_ok, elixir_source, ok}

        {:error, exception} ->
          {:transpile_ok, elixir_source, {:compile_raised, exception}}
      end
    rescue
      e -> {:transpile_raised, e}
    end
  end

  # --- Per-testcase classification (2-way: Elixir vs expected) ---------

  defp examples_from_testcases(source, testcases, opts) do
    if Keyword.get(opts, :no_examples, false) do
      []
    else
      max = Keyword.get(opts, :max_examples, 3)

      testcases
      |> Enum.take(max)
      |> Enum.flat_map(fn %{stdin: stdin, expected: expected} ->
        sha = TraceCache.key(source, stdin)

        case TraceCache.lookup(sha) do
          {:hit, envelope} ->
            [%{stdin: stdin, stdout: expected, trace_events: envelope}]

          :miss ->
            # Cache miss after the pre-warm pass means the tracer failed
            # (timeout / crash); drop this example.
            []
        end
      end)
    end
  end

  defp testcase_outcome(module, %{stdin: stdin, expected: expected}, elixir_timeout) do
    case Execute.run_elixir(module, elixir_timeout, stdin: stdin) do
      {:ok, ex_stdout} ->
        classify_2way(ex_stdout, expected, stdin)

      {:raised, exception} ->
        {:elixir_runtime_error, exception_module(exception),
         %{message: exception_message(exception), stdin: stdin, expected: expected}}

      :timeout ->
        {:elixir_timeout, %{stdin: stdin, expected: expected}}
    end
  end

  defp classify_2way(ex_stdout, expected, stdin) do
    base = %{stdin: stdin, expected: expected, elixir_stdout: ex_stdout}

    case Execute.compare(expected, ex_stdout) do
      :equal_empty -> {:ok_empty, base}
      :equal -> {:ok, base}
      {:differ, fp, summary} -> {:output_mismatch, fp, Map.put(base, :diff_summary, summary)}
    end
  end

  # --- Trace prewarm (example inference; CPython's only role) ----------

  # Populate `Eval.TraceCache` (trace envelope) for one `(source, stdin)`.
  # The dataset's solutions are deterministic, so a single tracer run
  # suffices — no determinism double-check. The example's stdout comes
  # from the dataset's `expected`, not the tracer.
  defp prewarm_trace(source, stdin, timeout_ms) do
    sha = TraceCache.key(source, stdin)

    if TraceCache.lookup(sha) == :miss do
      case Pylixir.ExampleInference.run_tracer_with_stdout(source, stdin,
             trace_timeout_ms: timeout_ms
           ) do
        {:ok, {_tracer_stdout, envelope}} ->
          TraceCache.put(sha, envelope)

        {:error, _reason} ->
          # Cache a "tracer failed" marker so subsequent runs skip the
          # retry. Treated as an empty trace downstream.
          TraceCache.put(sha, %{"events" => [], "uncaught" => nil, "truncated" => false})
      end
    end

    :ok
  end

  # --- Exception helpers -----------------------------------------------

  defp exception_module(e) when is_struct(e), do: e.__struct__
  defp exception_module(e) when is_atom(e), do: e
  defp exception_module(_), do: RuntimeError

  defp exception_message(e) when is_struct(e), do: Exception.message(e)
  defp exception_message(other), do: inspect(other)

  # --- Accumulator helpers ---------------------------------------------

  defp count_passed(per_tc), do: Enum.count(per_tc, &tc_passed?/1)

  defp tc_passed?({:ok, _}), do: true
  defp tc_passed?({:ok_empty, _}), do: true
  defp tc_passed?(_), do: false

  defp bump_count(acc, key),
    do: update_in(acc.counts[key], fn n -> (n || 0) + 1 end)

  defp bump_testcase_counts(acc, key, run, passed) do
    update_in(acc.testcase_counts[key], fn
      nil -> %{run: run, passed: passed}
      %{run: r, passed: p} -> %{run: r + run, passed: p + passed}
    end)
  end

  defp maybe_count_transpiled(acc, :ok),
    do: update_in(acc.totals.transpiled, &(&1 + 1))

  defp maybe_count_transpiled(acc, :ok_empty_output),
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

  # --- Limit / skip ----------------------------------------------------

  defp apply_limit_skip(enumerable, opts) do
    skip = opts[:skip] || 0
    limit = opts[:limit]

    enumerable =
      case skip do
        n when n > 0 -> Stream.drop(enumerable, n)
        _ -> enumerable
      end

    case limit do
      nil -> enumerable
      n when n > 0 -> Stream.take(enumerable, n)
      _ -> enumerable
    end
  end
end
