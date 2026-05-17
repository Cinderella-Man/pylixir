defmodule Pylixir.RuntimeHelpers.Regex do
  @moduledoc """
  Runtime helpers backing `Pylixir.Stdlib.Re`. Pattern strings come
  in raw (Python `r'...'` literal convention used in competitive
  code). We compile at runtime via `Regex.compile!/1` — Python's
  regex syntax is close enough to PCRE that the common patterns
  work unchanged. Returned shapes mirror Python: list-of-strings
  for findall, string|nil for search/match, rewritten string for
  sub.

  All defs are spliced into every generated `TranslatedCode` module
  via `Pylixir.HelpersCodegen` (between the sentinels below).
  """

  # --- HELPERS START ---

  def py_re_findall(pattern, string) when is_binary(pattern) and is_binary(string) do
    Regex.scan(Regex.compile!(pattern), string)
    |> Enum.map(fn
      [full] -> full
      [_full | groups] when length(groups) == 1 -> hd(groups)
      [_full | groups] -> List.to_tuple(groups)
    end)
  end

  def py_re_search(pattern, string) when is_binary(pattern) and is_binary(string) do
    case Regex.run(Regex.compile!(pattern), string) do
      nil -> nil
      [full | _] -> full
    end
  end

  def py_re_match(pattern, string) when is_binary(pattern) and is_binary(string) do
    case Regex.run(Regex.compile!("\\A" <> pattern), string) do
      nil -> nil
      [full | _] -> full
    end
  end

  def py_re_sub(pattern, repl, string)
      when is_binary(pattern) and is_binary(repl) and is_binary(string),
      do: Regex.replace(Regex.compile!(pattern), string, repl)

  def py_re_split(pattern, string) when is_binary(pattern) and is_binary(string),
    do: Regex.split(Regex.compile!(pattern), string)

  # `py_re_with_flags(pattern, flags)` — prepend the PCRE inline
  # modifier for each bit set in `flags`. `Pylixir.Stdlib.Re`'s
  # `@flag_bits` map keeps these in sync: DOTALL=1, MULTILINE=2,
  # IGNORECASE=4. Multiple flags combine via `|`, same as Python.
  # Inline modifiers are used (rather than the second arg of
  # `Regex.compile!`) because the pattern can still flow through
  # any helper that calls `Regex.compile!/1` unchanged.
  def py_re_with_flags(pattern, flags) when is_binary(pattern) and is_integer(flags) do
    prefix =
      [
        {1, "s"},
        {2, "m"},
        {4, "i"}
      ]
      |> Enum.filter(fn {bit, _} -> Bitwise.band(flags, bit) != 0 end)
      |> Enum.map_join("", fn {_, ch} -> ch end)

    case prefix do
      "" -> pattern
      flags_str -> "(?" <> flags_str <> ")" <> pattern
    end
  end

  # --- HELPERS END ---
end
