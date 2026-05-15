defmodule Pylixir do
  @moduledoc """
  Pylixir converts a Python AST (decoded JSON map) into Elixir source code.

  See `docs/rfc.md` for the full specification.
  """

  alias Pylixir.{Context, Converter, Formatter, ModuleAnalysis, PythonParseError}

  @default_python "python3.14"

  @doc """
  Convert a Python AST map (a parsed `Module` node) into Elixir source code.

  Pipeline (RFC §10.11):

    1. Run `Pylixir.ModuleAnalysis.analyze/1` over the module body — single
       pass that produces module attributes, function defs, runtime
       statements, and known-function names.
    2. Seed a fresh `Pylixir.Context` with the known-function set so call
       sites can forward-reference module-level defs.
    3. Dispatch via `Pylixir.Converter.convert/3` (Module clause consumes
       the analysis directly). Subsequent recursive calls use
       `Pylixir.Converter.convert/2`.
    4. Render the resulting Elixir AST through `Pylixir.Formatter.format/1`.

  Raises `Pylixir.UnsupportedNodeError` if the AST contains a node type that
  pylixir does not translate (RFC §4.4).
  """
  @spec to_source(map()) :: String.t()
  def to_source(python_ast) when is_map(python_ast) do
    analysis = ModuleAnalysis.analyze(python_ast["body"] || [])
    context = Context.new(analysis.known_functions)
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
    python_source
    |> python_ast()
    |> to_source()
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
