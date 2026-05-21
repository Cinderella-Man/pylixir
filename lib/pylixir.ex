defmodule Pylixir do
  @moduledoc """
  Pylixir converts a Python AST (decoded JSON map) into Elixir source code.

  See `docs/rfc.md` for the full specification.
  """

  alias Pylixir.{Converter, Formatter, Pipeline, PythonParseError}

  @default_python "python3.14"

  @doc """
  Convert a Python AST map (a parsed `Module` node) into Elixir source code.

  Pipeline (RFC §10.11):

    1. `Pylixir.Pipeline.run/3` runs the ordered module-top pre-passes
       — LiteralPropagation, ModuleAnalysis, Context init,
       ExampleInference, module_summary, seed_module_attr_types,
       Signatures.infer. See `Pylixir.Pipeline` for the full list and
       the rationale behind what does / does not live there.
    2. Dispatch via `Pylixir.Converter.convert/3` (Module clause consumes
       the analysis + pre-seeded context directly). Subsequent recursive
       calls use `Pylixir.Converter.convert/2`.
    3. Render the resulting Elixir AST through `Pylixir.Formatter.format/1`.

  Raises `Pylixir.UnsupportedNodeError` if the AST contains a node type that
  pylixir does not translate (RFC §4.4).
  """
  @spec to_source(map()) :: String.t()
  def to_source(python_ast) when is_map(python_ast), do: to_source(python_ast, [])

  @doc """
  Variant of `to_source/1` accepting options. Supported:

    * `:examples` — list of `%{stdin: String.t(), stdout: String.t()}` maps
      used to seed example-driven type inference (docs/09). When empty
      (default), behavior is identical to `to_source/1`.
  """
  @spec to_source(map(), keyword()) :: String.t()
  def to_source(python_ast, opts) when is_map(python_ast) and is_list(opts) do
    examples = Keyword.get(opts, :examples, [])
    source = Keyword.get(opts, :source)

    %{body: body, context: context, analysis: analysis} =
      Pipeline.run(python_ast["body"] || [], examples, source)

    python_ast = Map.put(python_ast, "body", body)

    {elixir_ast, _context} = Converter.convert(python_ast, context, analysis)
    Formatter.format(elixir_ast)
  end

  @doc """
  Convenience: take Python source as a string, shell out to the Python
  serialiser, decode, and run `to_source/1` on the result. Returns the
  generated Elixir source string.

  Raises `Pylixir.PythonParseError` if the Python source has a syntax
  error (or any other failure inside `serialize.py`).

  The Python interpreter defaults to `python3.14`; override via the
  `PYLIXIR_PYTHON` environment variable.
  """
  @spec transpile(String.t()) :: String.t()
  def transpile(python_source) when is_binary(python_source) do
    transpile(python_source, [])
  end

  @doc """
  Variant of `transpile/1` accepting options. See `to_source/2`.
  """
  @spec transpile(String.t(), keyword()) :: String.t()
  def transpile(python_source, opts) when is_binary(python_source) and is_list(opts) do
    opts = Keyword.put_new(opts, :source, python_source)

    python_source
    |> python_ast()
    |> to_source(opts)
  end

  @doc """
  Transpile `source` with `examples`, then run each example through
  `runner` and compare its stdout to the example's `:stdout`. Returns
  `:ok` when every example matches, otherwise `{:error, mismatches}`
  with one entry per failing example.

    * `runner :: (elixir_source, stdin) -> {:ok, stdout} | {:error, term}`

  Library stays pure — no `Code.eval_string`. The caller owns process
  sandboxing, timeouts, and stdout capture (docs/09 Q9 B).
  """
  @spec validate_transpile(String.t(), [map()], (String.t(), String.t() -> {:ok, String.t()} | {:error, term()})) ::
          :ok | {:error, [map()]}
  def validate_transpile(source, examples, runner)
      when is_binary(source) and is_list(examples) and is_function(runner, 2) do
    elixir_source = transpile(source, examples: examples)

    mismatches =
      examples
      |> Enum.with_index()
      |> Enum.reduce([], fn {%{stdin: stdin, stdout: expected} = _ex, idx}, acc ->
        case runner.(elixir_source, stdin) do
          {:ok, ^expected} ->
            acc

          {:ok, actual} ->
            [
              %{idx: idx, expected: expected, actual: actual, elixir_source: elixir_source}
              | acc
            ]

          {:error, err} ->
            [
              %{idx: idx, expected: expected, actual: {:error, err}, elixir_source: elixir_source}
              | acc
            ]
        end
      end)
      |> Enum.reverse()

    if mismatches == [], do: :ok, else: {:error, mismatches}
  end

  @doc false
  @spec python_ast(String.t()) :: map()
  def python_ast(python_source) when is_binary(python_source) do
    python = System.get_env("PYLIXIR_PYTHON") || @default_python
    script = Path.join([:code.priv_dir(:pylixir), "python", "serialize.py"])
    tmp = Path.join(System.tmp_dir!(), "pylixir-#{:erlang.unique_integer([:positive])}.py")
    File.write!(tmp, python_source)

    try do
      {stdout, _exit} = System.cmd(python, [script, tmp], stderr_to_stdout: false)
      decoded = Jason.decode!(stdout)

      case decoded do
        %{"error" => _kind, "message" => message} = env ->
          raise PythonParseError,
            message: message,
            lineno: Map.get(env, "lineno"),
            col_offset: Map.get(env, "col_offset"),
            text: Map.get(env, "text")

        ast ->
          ast
      end
    after
      File.rm(tmp)
    end
  end
end
