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
  def convert(%{"_type" => type} = node, _context) do
    raise UnsupportedNodeError,
      node_type: type,
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  @doc """
  Pre-pass over a Module body that collects every top-level `FunctionDef`
  name. Used to seed `Pylixir.Context.known_functions` so call sites can
  reference functions defined later in the source (RFC §10.3).

  Nested function definitions are deliberately excluded — they are local
  bindings, not module-level functions.
  """
  @spec collect_function_names([map()]) :: MapSet.t(String.t())
  def collect_function_names(body) when is_list(body) do
    body
    |> Enum.filter(&match?(%{"_type" => "FunctionDef"}, &1))
    |> Enum.map(& &1["name"])
    |> MapSet.new()
  end
end
