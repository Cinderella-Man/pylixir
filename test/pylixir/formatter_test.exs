defmodule Pylixir.FormatterTest do
  use ExUnit.Case, async: true

  alias Pylixir.Formatter

  describe "format/1" do
    test "round-trips a simple binary operation AST to a binary string" do
      ast = quote(do: 1 + 2)

      result = Formatter.format(ast)

      assert is_binary(result)
      assert result == "1 + 2"
    end

    test "produces a binary string (not iodata) — the iodata_to_binary step is wired" do
      ast = quote(do: foo(1, 2))

      result = Formatter.format(ast)

      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "applies mix-format conventions" do
      ast =
        quote do
          defmodule Foo do
            def bar, do: :ok
          end
        end

      result = Formatter.format(ast)

      assert is_binary(result)
      # mix format strips parens around defmodule and uses do/end blocks
      refute String.contains?(result, "defmodule(Foo)")
    end
  end
end
