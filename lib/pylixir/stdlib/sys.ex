defmodule Pylixir.Stdlib.Sys do
  @moduledoc """
  Pylixir.Stdlib implementation for a useful subset of Python's `sys`
  module. Initial support:

    * `sys.argv`       — `System.argv()`. Note: Python's `argv[0]` is the
      script path, Elixir's is just the first positional arg — semantics
      differ slightly for the leading element.
    * `sys.maxsize`    — `9_223_372_036_854_775_807` (BEAM-side int has
      no fixed maxsize; this matches CPython on 64-bit).
    * `sys.exit()` / `sys.exit(code)` — delegates to the same throw the
      `exit(...)` builtin uses, so py_main's `:pylixir_exit` catch
      wrapper picks it up.
    * `sys.stdin.read()` — `py_stdin_read/0` runtime helper (consumes
      all of stdin and returns it as a binary).
  """

  @behaviour Pylixir.Stdlib

  @impl true
  def attribute(["argv"], _node),
    do: {:ok, {{:., [], [{:__aliases__, [], [:System]}, :argv]}, [], []}}

  def attribute(["maxsize"], _node), do: {:ok, 9_223_372_036_854_775_807}

  def attribute(["stdin"], _node),
    do:
      {:error,
       "bare `sys.stdin` is not supported — use `sys.stdin.read()` to consume all of stdin as a string"}

  def attribute(["stdout"], _node),
    do: {:error, "bare `sys.stdout` is not supported — use `print(...)` or `sys.stdout.write(s)`"}

  def attribute(_path, _node), do: :no_clause

  @impl true
  def call(["exit"], [], _kwargs, _node),
    do: {:ok, Pylixir.ControlFlow.throw_exit(0)}

  def call(["exit"], [code], _kwargs, _node),
    do: {:ok, Pylixir.ControlFlow.throw_exit(code)}

  def call(["stdin", "read"], [], _kwargs, _node),
    do: {:ok, {:py_stdin_read, [], []}}

  def call(["stdout", "write"], [s], _kwargs, _node),
    do: {:ok, {{:., [], [{:__aliases__, [], [:IO]}, :write]}, [], [s]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause
end
