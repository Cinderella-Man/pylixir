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

  # Python `re` module-level flag constants. They lower to small
  # integers (Python's `re.RegexFlag` IntFlag values, though the
  # exact numbers don't matter here — Pylixir's runtime helper
  # bit-tests them and combines them with `|`). When `flags=<expr>`
  # is passed to a re.* call, the runtime prepends the equivalent
  # PCRE inline modifier (`(?s)` DOTALL, `(?m)` MULTILINE,
  # `(?i)` IGNORECASE) to the pattern before compiling.
  @flag_bits %{
    "DOTALL" => 1,
    "MULTILINE" => 2,
    "IGNORECASE" => 4
  }

  @impl true
  def attribute([name], _node) when is_map_key(@flag_bits, name),
    do: {:ok, Map.fetch!(@flag_bits, name)}

  def attribute(_path, _node), do: :no_clause

  @impl true
  def call(["findall"], [pattern, string], kwargs, _node),
    do: {:ok, {:py_re_findall, [], [with_flags(pattern, kwargs), string]}}

  def call(["search"], [pattern, string], kwargs, _node),
    do: {:ok, {:py_re_search, [], [with_flags(pattern, kwargs), string]}}

  def call(["match"], [pattern, string], kwargs, _node),
    do: {:ok, {:py_re_match, [], [with_flags(pattern, kwargs), string]}}

  def call(["sub"], [pattern, repl, string], kwargs, _node),
    do: {:ok, {:py_re_sub, [], [with_flags(pattern, kwargs), repl, string]}}

  def call(["split"], [pattern, string], kwargs, _node),
    do: {:ok, {:py_re_split, [], [with_flags(pattern, kwargs), string]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause

  defp with_flags(pattern, kwargs) do
    case Map.get(kwargs, "flags") do
      nil -> pattern
      flags_ast -> {:py_re_with_flags, [], [pattern, flags_ast]}
    end
  end

  @impl true
  def import_binding("findall"), do: {:ok, Pylixir.Stdlib.capture(:py_re_findall, 2)}
  def import_binding("search"), do: {:ok, Pylixir.Stdlib.capture(:py_re_search, 2)}
  def import_binding("match"), do: {:ok, Pylixir.Stdlib.capture(:py_re_match, 2)}
  def import_binding("sub"), do: {:ok, Pylixir.Stdlib.capture(:py_re_sub, 3)}
  def import_binding("split"), do: {:ok, Pylixir.Stdlib.capture(:py_re_split, 2)}
  def import_binding(_), do: :error
end
