defmodule Eval.Bucket do
  @moduledoc """
  Pure classification: given the outcome of attempting to transpile +
  compile one sample, return a `{bucket_key, metadata}` tuple. The
  orchestrator uses the bucket key as the aggregation dimension; the
  metadata is kept on the first K samples per bucket so triage has
  the per-failure detail without inflating accumulator size.

  Bucket key shapes:

    * `:ok` — transpile succeeded and the generated Elixir compiled
      cleanly (or only stylistic warnings).
    * `{:unsupported, node_type}` — `Pylixir.UnsupportedNodeError`.
    * `:parse_error` — `Pylixir.PythonParseError` (input is broken).
    * `{:compile_error, fingerprint}` — generated Elixir failed to
      compile. `fingerprint` is a short string derived from the first
      diagnostic message (stable enough to dedupe; loose enough to
      group similar causes).
    * `{:internal, exception_module}` — anything else; metadata
      captures `:message`.

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

  @type elixir_stage ::
          {:compile_ok, diagnostics :: [map()]}
          | {:compile_raised, Exception.t()}
          | {:execute_ok, diagnostics :: [map()],
             python_stdout :: String.t(), elixir_stdout :: String.t()}
          | {:execute_raised, diagnostics :: [map()], Exception.t() | atom()}
          | {:execute_timeout, diagnostics :: [map()]}

  @type outcome ::
          {:python_failed, python_failure(), metadata :: map()}
          | {:transpile_raised, Exception.t()}
          | {:transpile_ok, source :: String.t(), elixir_stage()}

  @type metadata :: %{optional(atom()) => any()}
  @type bucket_key ::
          :ok
          | :ok_empty_output
          | {:output_mismatch, fingerprint :: String.t()}
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

  @spec classify(sample(), outcome()) :: {bucket_key(), metadata()}

  # --- Python preflight outcomes (terminal — Elixir never ran) ---------

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

  # --- Elixir-side outcomes (Python succeeded or skipped) --------------

  def classify(_sample, {:transpile_ok, src, {:compile_ok, diagnostics}}) do
    real = Enum.reject(diagnostics, &stylistic?/1)

    case real do
      [] ->
        # Stash the generated Elixir on `:ok` metadata so
        # `Eval.Report.write/2`'s `--save-ok` path can write the
        # `.py` + `.ex` pair without re-transpiling. Other buckets
        # don't carry the source — they don't need it.
        {:ok, %{diagnostics: diagnostics, elixir_source: src}}

      [first | _] ->
        {{:compile_error, fingerprint(first)},
         %{diagnostic: Map.take(first, [:message, :position, :severity])}}
    end
  end

  def classify(_sample, {:transpile_ok, _src, {:compile_raised, exception}}) do
    {{:compile_error, "compile_quoted raised"},
     %{exception: inspect(exception.__struct__), message: Exception.message(exception)}}
  end

  def classify(_sample, {:transpile_ok, src, {:execute_ok, diagnostics, py_stdout, ex_stdout}}) do
    case Eval.Execute.compare_outputs(py_stdout, ex_stdout) do
      :equal_empty ->
        {:ok_empty_output, %{diagnostics: diagnostics, elixir_source: src}}

      :equal ->
        {:ok, %{diagnostics: diagnostics, elixir_source: src}}

      {:differ, fp, summary} ->
        {{:output_mismatch, fp},
         %{
           python_stdout: py_stdout,
           elixir_stdout: ex_stdout,
           diff_summary: summary,
           diagnostics: diagnostics,
           elixir_source: src
         }}
    end
  end

  def classify(_sample, {:transpile_ok, _src, {:execute_raised, diagnostics, exception}}) do
    mod = exception_module(exception)

    {{:elixir_runtime_error, mod},
     %{
       exception: inspect(mod),
       message: exception_message(exception),
       diagnostics: diagnostics
     }}
  end

  def classify(_sample, {:transpile_ok, _src, {:execute_timeout, diagnostics}}) do
    {:elixir_timeout, %{diagnostics: diagnostics}}
  end

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

  def slug({:elixir_runtime_error, module}),
    do: "elixir_runtime_error--" <> sanitize(inspect(module))

  def slug(:elixir_timeout), do: "elixir_timeout"
  def slug(:python_syntax_error), do: "python_syntax_error"
  def slug(:python_import_error), do: "python_import_error"

  def slug({:python_error, class}),
    do: "python_error--" <> sanitize(class)

  def slug(:python_timeout), do: "python_timeout"
  def slug(:nondeterministic_observed), do: "nondeterministic_observed"

  defp sanitize(s) do
    s
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.slice(0, 80)
  end

  # The golden corpus test treats these as non-correctness warnings;
  # apply the same filter here so the harness doesn't drown in
  # "X is unused" noise when classifying clean transpiles.
  defp stylistic?(%{message: msg}) when is_binary(msg) do
    msg =~ "is unused" or
      msg =~ "shadows" or
      msg =~ "underscored variable" or
      msg =~ "no clause matching" or
      # Elixir 1.19's type-checker warning fires on `py_band/py_bor/py_bxor`
      # results because they're typed as `integer() | %MapSet{}`. The
      # comparison still works correctly at runtime — this is a
      # soundness warning, not a correctness error.
      msg =~ "comparison with structs"
  end

  defp stylistic?(_), do: false

  defp fingerprint(%{message: msg}) when is_binary(msg) do
    msg
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 60)
  end

  defp fingerprint(_), do: "unknown"

  defp exception_module(e) when is_struct(e), do: e.__struct__
  defp exception_module(e) when is_atom(e), do: e
  defp exception_module(_), do: RuntimeError

  defp exception_message(e) when is_struct(e), do: Exception.message(e)
  defp exception_message(other), do: inspect(other)
end
