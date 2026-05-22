defmodule Dataset.NormalizeTest do
  use ExUnit.Case, async: true
  doctest Dataset.Normalize

  alias Dataset.Normalize, as: N

  test "trailing space/tab per line is trimmed (the noise we recover)" do
    assert N.normalize("1 2 3   \n") == "1 2 3"
    assert N.normalize("a\t\nb \t\n") == "a\nb"
    assert N.equal?("1 2 3 ", "1 2 3")
  end

  test "leading and internal spacing is preserved (never conflated)" do
    assert N.normalize("  a") == "  a"
    assert N.normalize("1 2 3") == "1 2 3"
    # structurally different output must NOT compare equal
    refute N.equal?("1 2 3", "1\n2\n3")
  end

  test "CRLF normalized to LF" do
    assert N.normalize("a\r\nb\r\n") == "a\nb"
    assert N.equal?("a\r\nb\r\n", "a\nb")
  end

  test "trailing blank lines and final newline dropped; internal blanks kept" do
    assert N.normalize("a\n\n\n") == "a"
    assert N.normalize("a\n") == "a"
    assert N.normalize("a\n\nb") == "a\n\nb"
  end

  test "empty / whitespace-only normalizes to empty" do
    assert N.normalize("") == ""
    assert N.normalize("\n\n") == ""
    assert N.normalize("   \n\t\n") == ""
  end

  test "invalid UTF-8 falls back to latin-1 instead of crashing" do
    out = N.normalize(<<0xFF, 0xFE, ?a>>)
    assert is_binary(out)
    assert String.valid?(out)
  end
end
