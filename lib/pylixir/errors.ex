defmodule Pylixir.PythonParseError do
  @moduledoc """
  Raised by `Pylixir.transpile/1` when the Python serializer reports a
  parse failure or internal error.

  Fields mirror the JSON envelope emitted by `priv/python/serialize.py`:
  `:message`, `:lineno`, `:col_offset`, `:text`. `:lineno`/`:col_offset` are
  `nil` for non-syntax errors.
  """

  defexception [:message, :lineno, :col_offset, :text]
end

defmodule Pylixir.UnsupportedNodeError do
  @moduledoc """
  Raised when the converter encounters a Python AST node type that pylixir
  does not translate.

  Fields:

    * `:node_type` — the offending `_type` string from the JSON AST.
    * `:hint` — short, per-node-type explanation (see `@hints` below). `nil`
      for node types we haven't authored a hint for yet.
    * `:lineno`, `:col_offset` — Python source location of the offending
      node, populated from the AST input when present. `nil` for synthesized
      or root-level nodes that don't carry positions.

  The full unsupported-node coverage matrix lives in T31; T03 lands the
  mechanism and a representative sampling of hints.
  """

  defexception [:node_type, :hint, :lineno, :col_offset, :message]

  @hints %{
    "ClassDef" =>
      "Python classes are not supported; use a module of functions plus a data map for state.",
    "AsyncFunctionDef" => "async def is not supported.",
    "Yield" => "generators (yield/yield from) are not supported.",
    "Match" => "match/case (structural pattern matching) is not supported."
  }

  @doc """
  Look up the canonical hint string for a given Python AST `_type`. Returns
  `nil` when no hint has been authored yet.
  """
  @spec hint_for(String.t()) :: String.t() | nil
  def hint_for(node_type) when is_binary(node_type), do: Map.get(@hints, node_type)

  @impl true
  def exception(opts) when is_list(opts) do
    node_type = Keyword.fetch!(opts, :node_type)
    hint = Keyword.get(opts, :hint) || hint_for(node_type)
    lineno = Keyword.get(opts, :lineno)
    col_offset = Keyword.get(opts, :col_offset)
    message = Keyword.get(opts, :message) || format_message(node_type, hint, lineno, col_offset)

    %__MODULE__{
      node_type: node_type,
      hint: hint,
      lineno: lineno,
      col_offset: col_offset,
      message: message
    }
  end

  defp format_message(node_type, hint, nil, _col_offset) do
    "#{node_type}: #{hint || "not supported"}"
  end

  defp format_message(node_type, hint, lineno, col_offset) do
    location = "line #{lineno}, col #{col_offset || 0}"
    "#{node_type} at #{location}: #{hint || "not supported"}"
  end
end
