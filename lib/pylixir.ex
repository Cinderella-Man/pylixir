defmodule Pylixir do
  @moduledoc """
  Pylixir converts a Python AST (decoded JSON map) into Elixir source code.

  See `docs/rfc.md` for the full specification.
  """

  @doc """
  Convert a Python AST map into Elixir source code.

  Stub implementation; returns an empty string. See RFC §1.2.
  """
  @spec to_source(map()) :: String.t()
  def to_source(_python_ast), do: ""
end
