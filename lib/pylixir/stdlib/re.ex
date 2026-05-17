defmodule Pylixir.Stdlib.Re do
  @moduledoc """
  Pylixir.Stdlib implementation for a useful subset of Python's `re`.
  Patterns are compiled at runtime via `Regex.compile!/1` — Python
  regex syntax is close enough to PCRE (Erlang/Elixir's engine) that
  the common competitive-programming patterns work unchanged.

  Currently supported:

    * `re.findall(pattern, string)` — list of matches (strings).
    * `re.search(pattern, string)` — first match string or `nil`.
    * `re.match(pattern, string)` — first match string anchored at start
      or `nil` (we prepend `\\A` rather than expose a Python `Match` object).
    * `re.sub(pattern, repl, string)` — substitute all occurrences.
    * `re.split(pattern, string)` — split on the pattern.

  Not yet: `re.compile`, `re.finditer`, Match objects, flags.
  """

  @behaviour Pylixir.Stdlib

  @impl true
  def attribute(_path, _node), do: :no_clause

  @impl true
  def call(["findall"], [pattern, string], _kwargs, _node),
    do: {:ok, {:py_re_findall, [], [pattern, string]}}

  def call(["search"], [pattern, string], _kwargs, _node),
    do: {:ok, {:py_re_search, [], [pattern, string]}}

  def call(["match"], [pattern, string], _kwargs, _node),
    do: {:ok, {:py_re_match, [], [pattern, string]}}

  def call(["sub"], [pattern, repl, string], _kwargs, _node),
    do: {:ok, {:py_re_sub, [], [pattern, repl, string]}}

  def call(["split"], [pattern, string], _kwargs, _node),
    do: {:ok, {:py_re_split, [], [pattern, string]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause

  @impl true
  def import_binding("findall"), do: {:ok, Pylixir.Stdlib.capture(:py_re_findall, 2)}
  def import_binding("search"), do: {:ok, Pylixir.Stdlib.capture(:py_re_search, 2)}
  def import_binding("match"), do: {:ok, Pylixir.Stdlib.capture(:py_re_match, 2)}
  def import_binding("sub"), do: {:ok, Pylixir.Stdlib.capture(:py_re_sub, 3)}
  def import_binding("split"), do: {:ok, Pylixir.Stdlib.capture(:py_re_split, 2)}
  def import_binding(_), do: :error
end
