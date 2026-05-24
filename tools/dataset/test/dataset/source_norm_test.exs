defmodule Dataset.SourceNormTest do
  # Shells out to python3.14 to canonicalize source via AST.
  use ExUnit.Case, async: true

  alias Dataset.SourceNorm

  test "struct mode: comment/whitespace/rename-only variants collide; real differences don't" do
    h =
      SourceNorm.hashes(
        [
          {"a", "s = input().strip()\nprint(s + s[::-1])"},
          {"b", "# reverse-append\nn = input().strip()\n\nprint(n + n[::-1])"},
          {"c", "s = input().strip()\nprint(s + s[1:])"}
        ],
        mode: "struct"
      )

    assert h["a"] == h["b"], "rename + comment only should canonicalize equal"
    assert h["a"] != h["c"], "different slice is a real difference"
  end

  test "reformat mode keeps identifier names distinct" do
    h =
      SourceNorm.hashes(
        [
          {"a", "s = input()\nprint(s)"},
          {"b", "n = input()\nprint(n)"}
        ],
        mode: "reformat"
      )

    assert h["a"] != h["b"]
  end

  test "unparseable source is omitted, valid neighbours still hashed" do
    h = SourceNorm.hashes([{"ok", "print(1)"}, {"bad", "def ("}], mode: "struct")
    assert Map.has_key?(h, "ok")
    refute Map.has_key?(h, "bad")
  end

  test "empty input returns empty map without spawning python" do
    assert SourceNorm.hashes([]) == %{}
  end
end
