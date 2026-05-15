defmodule Pylixir.HelpersCodegenTest do
  use ExUnit.Case, async: true

  alias Pylixir.HelpersCodegen

  describe "helpers_source/0" do
    test "returns a non-empty string between the sentinel comments" do
      source = HelpersCodegen.helpers_source()

      assert is_binary(source)
      assert byte_size(source) > 0
      refute source =~ "HELPERS START"
      refute source =~ "HELPERS END"
    end

    test "compiles inside a throwaway defmodule" do
      # Catches helper-source breakage at unit-test time rather than only
      # at end-to-end Module emission. If a future helper edit introduces
      # a syntax error or compiler warning, this test fails fast.
      source = HelpersCodegen.helpers_source()
      wrapped = "defmodule ThrowawayHelpersCompileTest do\n#{source}\nend"

      {_result, diagnostics} =
        Code.with_diagnostics(fn -> Code.compile_string(wrapped) end)

      assert diagnostics == [],
             "helper slice produced unexpected diagnostics: " <> inspect(diagnostics)
    end
  end

  describe "helpers_ast/0" do
    test "returns a non-empty list of AST nodes" do
      ast = HelpersCodegen.helpers_ast()

      assert is_list(ast)
      refute ast == []
    end

    test "every node is a `def` AST" do
      for node <- HelpersCodegen.helpers_ast() do
        assert match?({:def, _, _}, node),
               "non-def AST node found in helpers list: #{inspect(node, limit: 3)}"
      end
    end
  end
end
