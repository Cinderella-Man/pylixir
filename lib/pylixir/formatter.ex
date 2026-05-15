defmodule Pylixir.Formatter do
  @moduledoc """
  The tail of the conversion pipeline: turns an Elixir AST tuple into a
  formatted source string.

  Implements RFC §3.1 / §10.11 — the iodata step is not optional: without the
  final `IO.iodata_to_binary/1` the result is `iodata()`, not a binary, and
  string operations on it crash.
  """

  @doc """
  Render an Elixir AST to a formatted source string.
  """
  @spec format(Macro.t()) :: String.t()
  def format(elixir_ast) do
    elixir_ast
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end
end
