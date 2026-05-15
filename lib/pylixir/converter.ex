defmodule Pylixir.Converter do
  @moduledoc """
  Recursive dispatcher that walks a Python AST (decoded JSON map) and emits
  Elixir AST tuples (RFC §3.2).

  Each ticket adds clauses for new `_type` values. The default catch-all clause
  raises `Pylixir.UnsupportedNodeError` so silent omissions are impossible.
  """

  alias Pylixir.{Context, UnsupportedNodeError}

  @type elixir_ast :: Macro.t()

  @doc """
  Convert a single Python AST node to an Elixir AST tuple.

  Returns `{elixir_ast, updated_context}`. Threads the context through
  recursive calls so nested constructs can update scope / counters.
  """
  @spec convert(map(), Context.t()) :: {elixir_ast(), Context.t()}
  def convert(%{"_type" => type}, _context) do
    raise UnsupportedNodeError, node_type: type
  end
end
