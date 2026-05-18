defmodule Pylixir.LiteralFoldTest do
  use ExUnit.Case, async: true

  alias Pylixir.LiteralFold

  describe "str_repr/1 — quote choice" do
    test "plain string uses single quotes" do
      assert LiteralFold.str_repr("hello") == "'hello'"
    end

    test "empty string is two single quotes" do
      assert LiteralFold.str_repr("") == "''"
    end

    test "string with single quote and no double switches to double quotes" do
      assert LiteralFold.str_repr("it's") == ~s("it's")
    end

    test "string with double quote keeps single quotes" do
      assert LiteralFold.str_repr(~s(say "hi")) == ~s('say "hi"')
    end

    test "string with both quote types uses single, escapes inner singles" do
      assert LiteralFold.str_repr(~s(both 'a' and "b")) == ~s('both \\'a\\' and "b"')
    end
  end

  describe "str_repr/1 — escape table" do
    test "backslash escapes to double backslash" do
      assert LiteralFold.str_repr("a\\b") == "'a\\\\b'"
    end

    test "newline becomes \\n" do
      assert LiteralFold.str_repr("a\nb") == "'a\\nb'"
    end

    test "tab becomes \\t" do
      assert LiteralFold.str_repr("a\tb") == "'a\\tb'"
    end

    test "CR becomes \\r" do
      assert LiteralFold.str_repr("a\rb") == "'a\\rb'"
    end

    test "form-feed becomes \\x0c (NOT named in Python repr)" do
      assert LiteralFold.str_repr("a\fb") == "'a\\x0cb'"
    end

    test "vertical-tab becomes \\x0b (NOT named in Python repr)" do
      assert LiteralFold.str_repr("a\vb") == "'a\\x0bb'"
    end

    test "BEL becomes \\x07 (NOT named in Python repr)" do
      assert LiteralFold.str_repr("a\ab") == "'a\\x07b'"
    end

    test "BS becomes \\x08 (NOT named in Python repr)" do
      assert LiteralFold.str_repr("a\bb") == "'a\\x08b'"
    end

    test "NUL becomes \\x00" do
      assert LiteralFold.str_repr(<<0>>) == "'\\x00'"
    end

    test "DEL becomes \\x7f" do
      assert LiteralFold.str_repr(<<0x7F>>) == "'\\x7f'"
    end

    test "C1 control 0x80 becomes \\x80" do
      assert LiteralFold.str_repr(<<0x80::utf8>>) == "'\\x80'"
    end

    test "C1 control 0x9f becomes \\x9f" do
      assert LiteralFold.str_repr(<<0x9F::utf8>>) == "'\\x9f'"
    end

    test "printable unicode above 0x9F passes through" do
      # Python repr keeps printable codepoints raw (only uses \xNN /
      # \uNNNN for non-printables). 'á' (U+00E1) is printable.
      assert LiteralFold.str_repr("á") == "'á'"
    end

    test "mixed control chars in one string" do
      assert LiteralFold.str_repr("a\n\t\r\\b") == "'a\\n\\t\\r\\\\b'"
    end

    test "backslash followed by quote — Python switches to double quotes" do
      # Input is the 2-char string `\'` (backslash + single-quote).
      # Python repr prefers double-quote wrapping when the input
      # contains a single-quote and no double-quote, so we get
      # `"\\'"` (outer double quotes, backslash escaped, raw `'`
      # inside).
      assert LiteralFold.str_repr("\\'") == ~s("\\\\'")
    end
  end

  describe "repr_of/1 — scalars" do
    test "True / False / None" do
      assert LiteralFold.repr_of(true) == {:ok, "True"}
      assert LiteralFold.repr_of(false) == {:ok, "False"}
      assert LiteralFold.repr_of(nil) == {:ok, "None"}
    end

    test "integers" do
      assert LiteralFold.repr_of(0) == {:ok, "0"}
      assert LiteralFold.repr_of(42) == {:ok, "42"}
      assert LiteralFold.repr_of(-17) == {:ok, "-17"}
    end

    test "strings delegate to str_repr" do
      assert LiteralFold.repr_of("hi") == {:ok, "'hi'"}
      assert LiteralFold.repr_of("a\nb") == {:ok, "'a\\nb'"}
    end

    test "floats return :error (out of scope)" do
      assert LiteralFold.repr_of(1.5) == :error
      assert LiteralFold.repr_of(0.0) == :error
    end
  end

  describe "repr_of/1 — containers" do
    test "empty list" do
      assert LiteralFold.repr_of([]) == {:ok, "[]"}
    end

    test "list of ints" do
      assert LiteralFold.repr_of([1, 2, 3]) == {:ok, "[1, 2, 3]"}
    end

    test "list of mixed scalars" do
      assert LiteralFold.repr_of([1, "a", true, nil]) == {:ok, "[1, 'a', True, None]"}
    end

    test "list with non-foldable element returns :error" do
      assert LiteralFold.repr_of([1, 2.5, 3]) == :error
    end

    test "nested list" do
      assert LiteralFold.repr_of([[1, 2], [3, 4]]) == {:ok, "[[1, 2], [3, 4]]"}
    end

    test "empty tuple" do
      assert LiteralFold.repr_of({}) == {:ok, "()"}
    end

    test "single-element tuple gets trailing comma" do
      assert LiteralFold.repr_of({42}) == {:ok, "(42,)"}
    end

    test "n-element tuple" do
      assert LiteralFold.repr_of({1, "a", true}) == {:ok, "(1, 'a', True)"}
    end

    test "empty MapSet renders as `set()` per Python" do
      assert LiteralFold.repr_of(MapSet.new()) == {:ok, "set()"}
    end

    test "non-empty MapSet uses braces" do
      # MapSet ordering is insertion-ordered as a stable list; the
      # exact element order depends on the BEAM. Just check the
      # structural shell.
      {:ok, s} = LiteralFold.repr_of(MapSet.new([1]))
      assert s == "{1}"
    end

    test "empty map renders as `{}`" do
      assert LiteralFold.repr_of(%{}) == {:ok, "{}"}
    end

    test "single-pair map" do
      assert LiteralFold.repr_of(%{1 => "a"}) == {:ok, "{1: 'a'}"}
    end

    test "map with non-foldable value returns :error" do
      assert LiteralFold.repr_of(%{1 => 1.5}) == :error
    end
  end

  describe "str_of/1" do
    test "for binary, returns the binary unchanged (no quotes)" do
      assert LiteralFold.str_of("hello") == {:ok, "hello"}
      assert LiteralFold.str_of("with 'quote'") == {:ok, "with 'quote'"}
    end

    test "for non-binary, equivalent to repr_of" do
      assert LiteralFold.str_of(42) == {:ok, "42"}
      assert LiteralFold.str_of(true) == {:ok, "True"}
      assert LiteralFold.str_of([1, 2, 3]) == {:ok, "[1, 2, 3]"}
    end
  end
end
