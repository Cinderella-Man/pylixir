defmodule Pylixir do
  @moduledoc """
  Pylixir converts a Python AST (decoded JSON map) into Elixir source code.

  See `docs/rfc.md` for the full specification.
  """

  alias Pylixir.{Context, Converter, Formatter}

  @doc """
  Convert a Python AST map (a parsed `Module` node) into Elixir source code.

  Pipeline (RFC §10.11):

    1. Collect top-level function names for forward references.
    2. Seed a fresh `Pylixir.Context`.
    3. Recursively dispatch via `Pylixir.Converter.convert/2`.
    4. Render the resulting Elixir AST through `Pylixir.Formatter.format/1`.

  Raises `Pylixir.UnsupportedNodeError` if the AST contains a node type that
  pylixir does not translate (RFC §4.4).
  """
  @spec to_source(map()) :: String.t()
  def to_source(python_ast) when is_map(python_ast) do
    known = Converter.collect_function_names(python_ast["body"] || [])
    context = Context.new(known)
    {elixir_ast, _context} = Converter.convert(python_ast, context)
    Formatter.format(elixir_ast)
  end
end
