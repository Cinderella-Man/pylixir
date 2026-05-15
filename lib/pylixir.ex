defmodule Pylixir do
  @moduledoc """
  Pylixir converts a Python AST (decoded JSON map) into Elixir source code.

  See `docs/rfc.md` for the full specification.
  """

  alias Pylixir.{Context, Converter, Formatter, ModuleAnalysis}

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
end
