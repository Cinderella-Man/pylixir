defmodule Pylixir.UnsupportedNodeError do
  @moduledoc """
  Raised when the converter encounters a Python AST node type that pylixir
  does not translate. The `node_type` field carries the offending `_type`
  string (see RFC §4.4 for the full list of unsupported nodes).
  """

  defexception [:node_type, :message]

  @impl true
  def exception(opts) when is_list(opts) do
    node_type = Keyword.fetch!(opts, :node_type)
    message = Keyword.get(opts, :message, "unsupported Python AST node: #{node_type}")
    %__MODULE__{node_type: node_type, message: message}
  end
end
