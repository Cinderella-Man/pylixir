defmodule Eval.Bucket do
  @moduledoc """
  Pure classification: given the outcome of attempting to transpile +
  compile + execute one sample (across its testcase set), return a
  `{bucket_key, metadata}` tuple. The orchestrator uses the bucket key
  as the aggregation dimension; the metadata is kept on the first K
  samples per bucket so triage has the per-failure detail without
  inflating accumulator size.

  ## Per-testcase outcomes

  Each testcase produces one `tc_outcome` (see type below). For a
  sample, the per-testcase list is rolled up to a single bucket key
  via *worst-of* severity:

      5 — `:elixir_runtime_error`, `:elixir_timeout`  (Pylixir bug)
      4 — `:python_failed` (no ground truth — Python preflight died)
      3 — `:output_mismatch`                          (Pylixir bug)
      2 — `:python_disagrees_expected`                (sample broken)
      1 — `:ok` / `:ok_empty`                          (no problems)

  The first testcase at the highest severity drives the bucket key
  and fingerprint; the full per-testcase list is preserved in
  metadata for the `<NNN>.summary.md` writer.

  ## 4-way truth table for the comparable case

  When Python preflight succeeds AND Elixir runs successfully, the
  per-testcase outcome is decided by two comparisons:

  | py == expected | ex == py | tc_outcome                                    |
  |----------------|----------|-----------------------------------------------|
  | ✓              | ✓        | `{:ok, _}` / `{:ok_empty, _}`                 |
  | ✓              | ✗        | `{:output_mismatch, fp, meta}` (Pylixir bug)  |
  | ✗              | ✓        | `{:python_disagrees_expected, fp, meta}`      |
  | ✗              | ✗        | `{:output_mismatch, fp, meta}` (ex ≠ py wins) |

  Producing these tuples is the *caller's* job (the testcase callback
  in `Eval`, T8). This module only consumes them.

  This module is purposely pure — no I/O, no Pylixir dependencies —
  to keep it cheap to unit-test.
  """

  @type sample :: %{required(:id) => String.t(), required(:source) => String.t()}

  @type python_failure ::
          :syntax_error
          | :import_error
          | {:error, exception_class :: String.t()}
          | :timeout
          | :nondeterministic
          | :disagrees_expected

  @type tc_outcome ::
          {:ok, meta :: map()}
          | {:ok_empty, meta :: map()}
          | {:output_mismatch, fp :: String.t(), meta :: map()}
          | {:python_disagrees_expected, fp :: String.t(), meta :: map()}
          | {:elixir_runtime_error, exception_module :: module(), meta :: map()}
          | {:elixir_timeout, meta :: map()}
          | {:python_failed, python_failure(), meta :: map()}

  @type elixir_stage ::
          {:compile_raised, Exception.t()}
          | {:executed_testcases, diagnostics :: [map()], per_tc :: [tc_outcome()]}

  @type outcome ::
          {:python_failed, python_failure(), metadata :: map()}
          | {:transpile_raised, Exception.t()}
          | {:transpile_ok, source :: String.t(), elixir_stage()}

  @type metadata :: %{optional(atom()) => any()}
  @type bucket_key ::
          :ok
          | :ok_empty_output
          | {:output_mismatch, fingerprint :: String.t()}
          | {:python_disagrees_expected, fingerprint :: String.t()}
          | {:elixir_runtime_error, module()}
          | :elixir_timeout
          | :python_syntax_error
          | :python_import_error
          | {:python_error, exception_class :: String.t()}
          | :python_timeout
          | :nondeterministic_observed
          | {:unsupported, String.t()}
          | :parse_error
          | {:compile_error, String.t()}
          | {:internal, atom()}
          | {:example_conflict, String.t()}

  @spec classify(sample(), outcome()) :: {bucket_key(), metadata()}

  # --- Python preflight outcomes (sample-level, terminal) --------------
  #
  # These fire when the sample's Python is fundamentally broken (syntax
  # error, etc.) — independent of any testcase. The per-testcase pipeline
  # also produces these via `{:python_failed, kind, meta}` tc_outcomes
  # when Python dies on a specific stdin; those flow through the
  # `{:executed_testcases, ...}` clause below.

  def classify(_sample, {:python_failed, :syntax_error, meta}) do
    {:python_syntax_error, Map.take(meta, [:stderr_tail])}
  end

  def classify(_sample, {:python_failed, :import_error, meta}) do
    {:python_import_error, Map.take(meta, [:missing_module, :stderr_tail])}
  end

  def classify(_sample, {:python_failed, {:error, class}, meta}) do
    {{:python_error, class},
     Map.take(meta, [:exception_class, :exit_code, :stderr_tail])}
  end

  def classify(_sample, {:python_failed, :timeout, _meta}) do
    {:python_timeout, %{}}
  end

  def classify(_sample, {:python_failed, :nondeterministic, _meta}) do
    {:nondeterministic_observed, %{}}
  end

  def classify(_sample, {:python_failed, :disagrees_expected, meta}) do
    fp = Map.get(meta, :fingerprint, "unknown")

    {{:python_disagrees_expected, fp},
     Map.take(meta, [:python_stdout, :expected, :diff_summary])}
  end

  # --- Elixir-side outcomes --------------------------------------------

  def classify(_sample, {:transpile_ok, _src, {:compile_raised, exception}}) do
    {{:compile_error, "compile_quoted raised"},
     %{exception: inspect(exception.__struct__), message: Exception.message(exception)}}
  end

  def classify(_sample, {:transpile_ok, src, {:executed_testcases, diagnostics, per_tc}}) do
    {worst, worst_idx} = pick_worst(per_tc)
    build_sample_bucket(worst, worst_idx, src, diagnostics, per_tc)
  end

  # --- Transpile failures ----------------------------------------------

  def classify(_sample, {:transpile_raised, %Pylixir.UnsupportedNodeError{} = e}) do
    {{:unsupported, e.node_type},
     %{
       node_type: e.node_type,
       hint: e.hint,
       lineno: e.lineno,
       col_offset: e.col_offset
     }}
  end

  def classify(_sample, {:transpile_raised, %Pylixir.PythonParseError{} = e}) do
    {:parse_error, %{message: e.message, lineno: e.lineno, col_offset: e.col_offset}}
  end

  def classify(_sample, {:transpile_raised, %Pylixir.ExampleConflictError{} = e}) do
    reason = "#{e.name}_#{inspect(e.scope)}"
    {{:example_conflict, reason}, %{name: e.name, scope: e.scope, observed: e.observed}}
  end

  def classify(_sample, {:transpile_raised, exception}) do
    {{:internal, exception.__struct__}, %{message: Exception.message(exception)}}
  end

  @doc """
  Filesystem-safe slug for a bucket key. Used by `Eval.Report` to name
  per-bucket subdirectories.
  """
  @spec slug(bucket_key()) :: String.t()
  def slug(:ok), do: "ok"
  def slug(:ok_empty_output), do: "ok_empty_output"
  def slug(:parse_error), do: "parse_error"
  def slug({:unsupported, node_type}), do: "unsupported--" <> sanitize(node_type)

  def slug({:compile_error, fingerprint}),
    do: "compile_error--" <> sanitize(fingerprint)

  def slug({:internal, module}),
    do: "internal--" <> sanitize(inspect(module))

  def slug({:output_mismatch, fingerprint}),
    do: "output_mismatch--" <> sanitize(fingerprint)

  def slug({:python_disagrees_expected, fingerprint}),
    do: "python_disagrees_expected--" <> sanitize(fingerprint)

  def slug({:elixir_runtime_error, module}),
    do: "elixir_runtime_error--" <> sanitize(inspect(module))

  def slug(:elixir_timeout), do: "elixir_timeout"
  def slug(:python_syntax_error), do: "python_syntax_error"
  def slug(:python_import_error), do: "python_import_error"

  def slug({:python_error, class}),
    do: "python_error--" <> sanitize(class)

  def slug(:python_timeout), do: "python_timeout"
  def slug(:nondeterministic_observed), do: "nondeterministic_observed"

  def slug({:example_conflict, reason}), do: "example_conflict--" <> sanitize(reason)

  # --- Worst-of rollup -------------------------------------------------

  defp pick_worst(per_tc) do
    per_tc
    |> Enum.with_index()
    |> Enum.max_by(fn {tc, _idx} -> severity(tc) end)
  end

  defp severity({:elixir_runtime_error, _, _}), do: 5
  defp severity({:elixir_timeout, _}), do: 5
  defp severity({:python_failed, _, _}), do: 4
  defp severity({:output_mismatch, _, _}), do: 3
  defp severity({:python_disagrees_expected, _, _}), do: 2
  defp severity({:ok, _}), do: 1
  defp severity({:ok_empty, _}), do: 1

  defp build_sample_bucket({:elixir_runtime_error, mod, meta}, idx, src, diagnostics, per_tc) do
    {{:elixir_runtime_error, mod},
     %{
       exception: inspect(mod),
       message: Map.get(meta, :message),
       failing_index: idx,
       diagnostics: diagnostics,
       elixir_source: src,
       per_testcase: per_tc
     }}
  end

  defp build_sample_bucket({:elixir_timeout, _meta}, idx, src, diagnostics, per_tc) do
    {:elixir_timeout,
     %{
       failing_index: idx,
       diagnostics: diagnostics,
       elixir_source: src,
       per_testcase: per_tc
     }}
  end

  defp build_sample_bucket({:python_failed, kind, meta}, idx, src, diagnostics, per_tc) do
    {bucket_key, extra} = python_failure_bucket(kind, meta)

    metadata =
      extra
      |> Map.put(:failing_index, idx)
      |> Map.put(:diagnostics, diagnostics)
      |> Map.put(:elixir_source, src)
      |> Map.put(:per_testcase, per_tc)

    {bucket_key, metadata}
  end

  defp build_sample_bucket({:output_mismatch, fp, meta}, idx, src, diagnostics, per_tc) do
    {{:output_mismatch, fp},
     %{
       python_stdout: Map.get(meta, :python_stdout),
       elixir_stdout: Map.get(meta, :elixir_stdout),
       diff_summary: Map.get(meta, :diff_summary),
       failing_index: idx,
       diagnostics: diagnostics,
       elixir_source: src,
       per_testcase: per_tc
     }}
  end

  defp build_sample_bucket({:python_disagrees_expected, fp, meta}, idx, src, diagnostics, per_tc) do
    {{:python_disagrees_expected, fp},
     %{
       python_stdout: Map.get(meta, :python_stdout),
       expected: Map.get(meta, :expected),
       diff_summary: Map.get(meta, :diff_summary),
       failing_index: idx,
       diagnostics: diagnostics,
       elixir_source: src,
       per_testcase: per_tc
     }}
  end

  defp build_sample_bucket({:ok, _meta}, _idx, src, diagnostics, per_tc) do
    bucket =
      if Enum.all?(per_tc, &match?({:ok_empty, _}, &1)),
        do: :ok_empty_output,
        else: :ok

    {bucket,
     %{
       diagnostics: diagnostics,
       elixir_source: src,
       per_testcase: per_tc
     }}
  end

  defp build_sample_bucket({:ok_empty, _meta}, _idx, src, diagnostics, per_tc) do
    bucket =
      if Enum.all?(per_tc, &match?({:ok_empty, _}, &1)),
        do: :ok_empty_output,
        else: :ok

    {bucket,
     %{
       diagnostics: diagnostics,
       elixir_source: src,
       per_testcase: per_tc
     }}
  end

  defp python_failure_bucket(:syntax_error, meta),
    do: {:python_syntax_error, Map.take(meta, [:stderr_tail])}

  defp python_failure_bucket(:import_error, meta),
    do: {:python_import_error, Map.take(meta, [:missing_module, :stderr_tail])}

  defp python_failure_bucket({:error, class}, meta),
    do:
      {{:python_error, class},
       Map.take(meta, [:exception_class, :exit_code, :stderr_tail])}

  defp python_failure_bucket(:timeout, _meta), do: {:python_timeout, %{}}
  defp python_failure_bucket(:nondeterministic, _meta), do: {:nondeterministic_observed, %{}}

  defp python_failure_bucket(:disagrees_expected, meta) do
    fp = Map.get(meta, :fingerprint, "unknown")

    {{:python_disagrees_expected, fp},
     Map.take(meta, [:python_stdout, :expected, :diff_summary])}
  end

  # --- Helpers ---------------------------------------------------------

  defp sanitize(s) do
    s
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.slice(0, 80)
  end
end
