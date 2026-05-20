defmodule Eval do
  @moduledoc """
  Orchestrates the dataset evaluation pipeline:

      Eval.Stream.stream/1
        ↳ Task.async_stream(&attempt/2)
            ↳ Python preflight (cached) → Pylixir.transpile → compile (+ execute)
            ↳ Eval.Bucket.classify/2
                ↳ accumulator that holds counts + first K samples per bucket

  `run/1` returns the accumulator. `Eval.Report.write/2` consumes it.

  ## Behavioral equivalence (`:execute` opt, default `true`)

  When enabled, each sample is run through CPython first (twice, for a
  determinism check) and the resulting stdout cached at
  `tools/eval/cache/python.jsonl`. Then the transpiled Elixir's
  `py_main/0` runs under `Eval.Execute.run_elixir/2`; its stdout is
  byte-compared against the cached Python stdout. See `Eval.Bucket`
  for the resulting bucket keys.

  When disabled (`--no-execute`), the pipeline matches v1: transpile
  + compile only.
  """

  alias Eval.{Bucket, Compile, Execute, PythonCache}

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
          | {:execute, boolean()}
          | {:python_timeout_ms, pos_integer()}
          | {:elixir_timeout_ms, pos_integer()}
          | {:on_sample, (map() -> any())}
        ]

  @default_concurrency_multiplier 2
  @default_samples_per_bucket 10
  @default_python_timeout_ms 3_000
  @default_elixir_timeout_ms 5_000

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
    # `--save-ok N` overrides the cap *only for the :ok bucket* — the
    # showcase workflow wants more clean transpiles than failures.
    save_ok = opts[:save_ok] || 0
    on_sample = opts[:on_sample] || fn _ -> :ok end
    # Library default is OFF — execute mode requires `Eval.PythonCache`
    # to be running. The Mix task explicitly opts in (defaulting to ON
    # at the CLI level) after ensuring the cache is up.
    execute? = Keyword.get(opts, :execute, false)
    python_timeout = opts[:python_timeout_ms] || @default_python_timeout_ms
    elixir_timeout = opts[:elixir_timeout_ms] || @default_elixir_timeout_ms

    attempt_opts = [
      execute: execute?,
      python_timeout_ms: python_timeout,
      elixir_timeout_ms: elixir_timeout
    ]

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
          %{"id" => id, "source" => source} -> attempt(%{id: id, source: source}, attempt_opts)
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
        cap = if bucket_key == :ok, do: save_ok, else: samples_per_bucket

        acc
        |> update_in([:totals, :processed], &(&1 + 1))
        |> maybe_count_transpiled(bucket_key)
        |> bump_count(bucket_key)
        |> maybe_store_sample(bucket_key, sample, metadata, cap)

      {:exit, reason}, acc ->
        IO.warn("worker task exited: #{inspect(reason)}")
        acc
    end)
  end

  @spec attempt(Bucket.sample(), keyword()) ::
          {Bucket.sample(), Bucket.bucket_key(), map()}
  def attempt(%{source: source} = sample, opts) do
    outcome =
      if Keyword.get(opts, :execute, false) do
        attempt_with_execution(source, opts)
      else
        attempt_compile_only(source)
      end

    {bucket, metadata} = Bucket.classify(sample, outcome)
    {sample, bucket, metadata}
  end

  # --- Compile-only path (--no-execute) -----------------------------

  defp attempt_compile_only(source) do
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
  end

  # --- Execute path (default) ---------------------------------------

  defp attempt_with_execution(source, opts) do
    python_timeout = Keyword.fetch!(opts, :python_timeout_ms)
    elixir_timeout = Keyword.fetch!(opts, :elixir_timeout_ms)

    case python_outcome(source, python_timeout) do
      {:python_ok, py_stdout} ->
        transpile_and_execute(source, py_stdout, elixir_timeout)

      {:python_failed, _kind, _meta} = failure ->
        failure
    end
  end

  defp python_outcome(source, timeout_ms) do
    sha = PythonCache.key(source)

    case PythonCache.lookup(sha) do
      {:hit, entry} ->
        entry_to_outcome(entry)

      :miss ->
        entry = run_python_twice(source, timeout_ms)
        PythonCache.put(sha, entry)
        entry_to_outcome(entry)
    end
  end

  # Two consecutive Python runs determine whether the sample is
  # deterministic. If both succeed with identical stdout → cache the
  # stdout. Any divergence (different output, second-run failure
  # after first-run success, etc.) becomes `:nondeterministic`. A
  # first-run failure short-circuits without a second run.
  defp run_python_twice(source, timeout_ms) do
    case Execute.run_python(source, timeout_ms: timeout_ms) do
      {:ok, stdout1} ->
        case Execute.run_python(source, timeout_ms: timeout_ms) do
          {:ok, ^stdout1} ->
            %{"outcome" => "ok", "stdout" => stdout1}

          {:ok, _other} ->
            %{"outcome" => "nondeterministic"}

          {:exit, _code, _output} ->
            %{"outcome" => "nondeterministic"}

          :timeout ->
            %{"outcome" => "nondeterministic"}
        end

      {:exit, code, output} ->
        {kind, extra} = parse_python_failure(output)

        Map.merge(
          %{
            "outcome" => kind,
            "exit_code" => code,
            "stderr_tail" => last_chars(output, 1024)
          },
          extra
        )

      :timeout ->
        %{"outcome" => "timeout"}
    end
  end

  defp entry_to_outcome(%{"outcome" => "ok", "stdout" => stdout}),
    do: {:python_ok, stdout}

  defp entry_to_outcome(%{"outcome" => "syntax_error"} = e),
    do: {:python_failed, :syntax_error, %{stderr_tail: e["stderr_tail"]}}

  defp entry_to_outcome(%{"outcome" => "import_error"} = e),
    do: {:python_failed, :import_error,
         %{missing_module: e["missing_module"], stderr_tail: e["stderr_tail"]}}

  defp entry_to_outcome(%{"outcome" => "error"} = e),
    do: {:python_failed, {:error, e["exception_class"] || "Unknown"},
         %{
           exception_class: e["exception_class"],
           exit_code: e["exit_code"],
           stderr_tail: e["stderr_tail"]
         }}

  defp entry_to_outcome(%{"outcome" => "timeout"}),
    do: {:python_failed, :timeout, %{}}

  defp entry_to_outcome(%{"outcome" => "nondeterministic"}),
    do: {:python_failed, :nondeterministic, %{}}

  # Defensive: unknown / malformed cache entries fall through as
  # `:error` so the run continues. Should be rare given the schema
  # filter on cache load.
  defp entry_to_outcome(_),
    do: {:python_failed, {:error, "Unknown"}, %{exception_class: "Unknown"}}

  defp transpile_and_execute(source, py_stdout, timeout_ms) do
    try do
      elixir_source = Pylixir.transpile(source)

      case Compile.check_and_execute(elixir_source, timeout_ms) do
        {:ok, diagnostics, ex_stdout} ->
          {:transpile_ok, elixir_source,
           {:execute_ok, diagnostics, py_stdout, ex_stdout}}

        {:raised, diagnostics, exception} ->
          {:transpile_ok, elixir_source, {:execute_raised, diagnostics, exception}}

        {:timeout, diagnostics} ->
          {:transpile_ok, elixir_source, {:execute_timeout, diagnostics}}

        {:error, exception} ->
          {:transpile_ok, elixir_source, {:compile_raised, exception}}
      end
    rescue
      e -> {:transpile_raised, e}
    end
  end

  # Parse the *last* non-empty line of a Python traceback to determine
  # the exception class. Lines like `SyntaxError: invalid syntax` or
  # `ModuleNotFoundError: No module named 'numpy'` are routed to
  # dedicated buckets; everything else lands in `{:python_error, Class}`.
  defp parse_python_failure(stderr) do
    last_line =
      stderr
      |> String.split("\n", trim: true)
      |> List.last()

    case last_line do
      nil ->
        {"error", %{"exception_class" => "Unknown"}}

      line ->
        cond do
          syntax_class?(line) ->
            class = extract_class(line) || "SyntaxError"
            {"syntax_error", %{"exception_class" => class}}

          import_class?(line) ->
            class = extract_class(line) || "ImportError"
            {"import_error",
             %{"exception_class" => class, "missing_module" => extract_missing_module(line)}}

          true ->
            class = extract_class(line) || "Unknown"
            {"error", %{"exception_class" => class}}
        end
    end
  end

  defp syntax_class?(line) do
    String.starts_with?(line, "SyntaxError:") or
      String.starts_with?(line, "IndentationError:") or
      String.starts_with?(line, "TabError:")
  end

  defp import_class?(line) do
    String.starts_with?(line, "ImportError:") or
      String.starts_with?(line, "ModuleNotFoundError:")
  end

  defp extract_class(line) do
    case Regex.run(~r/^([A-Z][A-Za-z0-9_]*):/, line) do
      [_, class] -> class
      nil -> nil
    end
  end

  defp extract_missing_module(line) do
    case Regex.run(~r/No module named ['"]([^'"]+)['"]/, line) do
      [_, mod] -> mod
      nil -> nil
    end
  end

  defp last_chars(s, n) when byte_size(s) <= n, do: s

  defp last_chars(s, n) do
    skip = byte_size(s) - n
    binary_part(s, skip, n)
  end

  defp bump_count(acc, key),
    do: update_in(acc.counts[key], fn n -> (n || 0) + 1 end)

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
end
