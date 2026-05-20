defmodule Eval do
  @moduledoc """
  Orchestrates the dataset evaluation pipeline:

      Eval.Corpus.build/1                          # joined seed_sft + seed_testcase
        ↳ Task.async_stream(&attempt/2)
            ↳ Pylixir.transpile  →  Compile.check_and_execute_testcases
                ↳ per testcase: Python preflight (cached) + Elixir run + 4-way classify
            ↳ Eval.Bucket.classify/2 (worst-of rollup)
                ↳ accumulator that holds counts + first K samples per bucket

  `run/1` returns the accumulator. `Eval.Report.write/2` consumes it.

  ## Per-testcase semantics

  Each sample carries a list of `%{stdin, expected}` testcases drawn
  from `seed_testcase`. For each testcase, we run CPython with that
  stdin (cached by `sha256(source <> \"\\0\" <> stdin)`) and compare:

    * Python actual ⟷ dataset expected — lenient (trailing-newline
      tolerant). A mismatch flags the *sample*, not Pylixir.
    * Elixir actual ⟷ Python actual — strict (byte-equal modulo CRLF).
      A mismatch flags Pylixir.

  Per-sample bucket is the worst-of across all testcases. See
  `Eval.Bucket` for the severity ladder and bucket keys.
  """

  alias Eval.{Bucket, Compile, Corpus, Execute, PythonCache}

  @type accumulator :: %{
          counts: %{Bucket.bucket_key() => non_neg_integer()},
          # Per-bucket sub-counts: how many testcases were observed for
          # samples that landed in this bucket, and how many of those
          # testcases passed. Lets the run summary show e.g.
          # `ok: 58 samples / 1247 testcases passed` instead of forcing
          # the reader to divide the global totals manually.
          testcase_counts: %{
            Bucket.bucket_key() => %{
              run: non_neg_integer(),
              passed: non_neg_integer()
            }
          },
          samples: %{Bucket.bucket_key() => [sample_entry()]},
          totals: %{
            processed: non_neg_integer(),
            transpiled: non_neg_integer(),
            testcases_run: non_neg_integer(),
            testcases_passed: non_neg_integer(),
            testcase_shard_missing: non_neg_integer()
          }
        }

  @type sample_entry :: %{id: String.t(), source: String.t(), metadata: map()}

  @type opts :: [
          {:limit, pos_integer()}
          | {:skip, non_neg_integer()}
          | {:concurrency, pos_integer()}
          | {:samples_per_bucket, pos_integer()}
          | {:save_ok, non_neg_integer()}
          | {:testcase_shards, pos_integer()}
          | {:python_timeout_ms, pos_integer()}
          | {:elixir_timeout_ms, pos_integer()}
          | {:on_sample, (map() -> any())}
          | {:samples, Enumerable.t()}
          | {:corpus_stats, map()}
        ]

  @default_concurrency_multiplier 2
  @default_samples_per_bucket 10
  @default_python_timeout_ms 3_000
  @default_elixir_timeout_ms 5_000

  @spec run(opts()) :: accumulator()
  def run(opts \\ []) do
    {enumerable, corpus_stats} =
      case Keyword.fetch(opts, :samples) do
        {:ok, samples} ->
          {samples, Keyword.get(opts, :corpus_stats, %{})}

        :error ->
          testcase_shards = Keyword.get(opts, :testcase_shards, 1)
          Corpus.build(testcase_shards: testcase_shards)
      end

    enumerable = apply_limit_skip(enumerable, opts)
    process(enumerable, Keyword.put(opts, :corpus_stats, corpus_stats))
  end

  @doc """
  Run the classification pipeline against any enumerable of corpus
  records (`%{id: _, source: _, testcases: _}`).

  Exposed so tests can drive the harness without booting the real
  corpus build.
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
    python_timeout = opts[:python_timeout_ms] || @default_python_timeout_ms
    elixir_timeout = opts[:elixir_timeout_ms] || @default_elixir_timeout_ms
    corpus_stats = opts[:corpus_stats] || %{}

    attempt_opts = [
      python_timeout_ms: python_timeout,
      elixir_timeout_ms: elixir_timeout
    ]

    initial = %{
      counts: %{},
      testcase_counts: %{},
      samples: %{},
      totals: %{
        processed: 0,
        transpiled: 0,
        testcases_run: 0,
        testcases_passed: 0,
        testcase_shard_missing: Map.get(corpus_stats, :testcase_shard_missing, 0)
      }
    }

    enumerable
    |> Stream.each(on_sample)
    |> Task.async_stream(
      fn record -> attempt(record, attempt_opts) end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: :infinity
    )
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

    try do
      elixir_source = Pylixir.transpile(source)

      result =
        Compile.check_and_execute_testcases(
          elixir_source,
          testcases,
          elixir_timeout,
          fn module, tc -> testcase_outcome(module, tc, source, opts) end
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

  # --- Per-testcase classification (4-way truth table) -----------------

  defp testcase_outcome(module, %{stdin: stdin, expected: expected}, source, opts) do
    python_timeout = Keyword.fetch!(opts, :python_timeout_ms)
    elixir_timeout = Keyword.fetch!(opts, :elixir_timeout_ms)

    case python_outcome(source, stdin, python_timeout) do
      {:python_ok, py_stdout} ->
        run_elixir_and_classify(module, stdin, expected, py_stdout, elixir_timeout)

      {:python_failed, kind, meta} ->
        {:python_failed, kind, Map.merge(meta, %{stdin: stdin, expected: expected})}
    end
  end

  defp run_elixir_and_classify(module, stdin, expected, py_stdout, elixir_timeout) do
    case Execute.run_elixir(module, elixir_timeout, stdin: stdin) do
      {:ok, ex_stdout} ->
        classify_4way(ex_stdout, py_stdout, expected, stdin)

      {:raised, exception} ->
        {:elixir_runtime_error, exception_module(exception),
         %{
           message: exception_message(exception),
           stdin: stdin,
           expected: expected,
           python_stdout: py_stdout
         }}

      :timeout ->
        {:elixir_timeout,
         %{stdin: stdin, expected: expected, python_stdout: py_stdout}}
    end
  end

  # 4-way truth table:
  #   py == expected | ex == py | tc_outcome
  #   ✓              | ✓        | :ok / :ok_empty
  #   ✓              | ✗        | {:output_mismatch, fp, _}
  #   ✗              | ✓        | {:python_disagrees_expected, fp, _}
  #   ✗              | ✗        | {:output_mismatch, fp, _}  (ex-vs-py dominates)
  defp classify_4way(ex_stdout, py_stdout, expected, stdin) do
    py_vs_expected = Execute.compare_lenient(py_stdout, expected)
    ex_vs_py = Execute.compare_outputs(py_stdout, ex_stdout)

    base = %{
      stdin: stdin,
      expected: expected,
      python_stdout: py_stdout,
      elixir_stdout: ex_stdout
    }

    case {match_ok?(py_vs_expected), match_ok?(ex_vs_py)} do
      {true, true} ->
        if ex_vs_py == :equal_empty,
          do: {:ok_empty, base},
          else: {:ok, base}

      {true, false} ->
        {:differ, fp, summary} = ex_vs_py
        {:output_mismatch, fp, Map.put(base, :diff_summary, summary)}

      {false, true} ->
        {:differ, fp, summary} = py_vs_expected
        {:python_disagrees_expected, fp, Map.put(base, :diff_summary, summary)}

      {false, false} ->
        {:differ, fp, summary} = ex_vs_py
        {:output_mismatch, fp, Map.put(base, :diff_summary, summary)}
    end
  end

  defp match_ok?(:equal), do: true
  defp match_ok?(:equal_empty), do: true
  defp match_ok?({:differ, _, _}), do: false

  # --- Python preflight (per (source, stdin)) --------------------------

  defp python_outcome(source, stdin, timeout_ms) do
    sha = PythonCache.key(source, stdin)

    case PythonCache.lookup(sha) do
      {:hit, entry} ->
        entry_to_outcome(entry)

      :miss ->
        entry = run_python_twice(source, stdin, timeout_ms)
        PythonCache.put(sha, entry)
        entry_to_outcome(entry)
    end
  end

  # Two consecutive Python runs determine whether the sample is
  # deterministic. If both succeed with identical stdout → cache the
  # stdout. Any divergence (different output, second-run failure
  # after first-run success, etc.) becomes `:nondeterministic`. A
  # first-run failure short-circuits without a second run.
  defp run_python_twice(source, stdin, timeout_ms) do
    case Execute.run_python(source, timeout_ms: timeout_ms, stdin: stdin) do
      {:ok, stdout1} ->
        case Execute.run_python(source, timeout_ms: timeout_ms, stdin: stdin) do
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
    do:
      {:python_failed, :import_error,
       %{missing_module: e["missing_module"], stderr_tail: e["stderr_tail"]}}

  defp entry_to_outcome(%{"outcome" => "error"} = e),
    do:
      {:python_failed, {:error, e["exception_class"] || "Unknown"},
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

  # --- Exception helpers -----------------------------------------------

  defp exception_module(e) when is_struct(e), do: e.__struct__
  defp exception_module(e) when is_atom(e), do: e
  defp exception_module(_), do: RuntimeError

  defp exception_message(e) when is_struct(e), do: Exception.message(e)
  defp exception_message(other), do: inspect(other)

  # --- Accumulator helpers ---------------------------------------------

  defp count_passed(per_tc) do
    Enum.count(per_tc, &tc_passed?/1)
  end

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
