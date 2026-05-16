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
  @type outcome ::
          {:transpile_raised, Exception.t()}
          | {:transpile_ok, source :: String.t(),
             {:compile_ok, diagnostics :: [map()]}
             | {:compile_raised, Exception.t()}}

  @type metadata :: %{optional(atom()) => any()}
  @type bucket_key ::
          :ok
          | {:unsupported, String.t()}
          | :parse_error
          | {:compile_error, String.t()}
          | {:internal, atom()}

  @spec classify(sample(), outcome()) :: {bucket_key(), metadata()}
  def classify(_sample, {:transpile_ok, _src, {:compile_ok, diagnostics}}) do
    real = Enum.reject(diagnostics, &stylistic?/1)

    case real do
      [] ->
        {:ok, %{diagnostics: diagnostics}}

      [first | _] ->
        {{:compile_error, fingerprint(first)},
         %{diagnostic: Map.take(first, [:message, :position, :severity])}}
    end
  end

  def classify(_sample, {:transpile_ok, _src, {:compile_raised, exception}}) do
    {{:compile_error, "compile_quoted raised"},
     %{exception: inspect(exception.__struct__), message: Exception.message(exception)}}
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
  def slug(:parse_error), do: "parse_error"
  def slug({:unsupported, node_type}), do: "unsupported--" <> sanitize(node_type)

  def slug({:compile_error, fingerprint}),
    do: "compile_error--" <> sanitize(fingerprint)

  def slug({:internal, module}),
    do: "internal--" <> sanitize(inspect(module))

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
      msg =~ "no clause matching"
  end

  defp stylistic?(_), do: false

  defp fingerprint(%{message: msg}) when is_binary(msg) do
    msg
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 60)
  end

  defp fingerprint(_), do: "unknown"
end
