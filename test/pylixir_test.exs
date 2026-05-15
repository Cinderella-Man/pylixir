defmodule PylixirTest do
  use ExUnit.Case, async: true
  doctest Pylixir

  alias Pylixir.TranspileHelpers

  describe "to_source/1 on an empty Module — T05 acceptance" do
    test "produces a string containing the wrapper module + trailing call" do
      output = Pylixir.to_source(%{"_type" => "Module", "body" => []})

      assert is_binary(output)
      assert output =~ "defmodule TranslatedCode"
      assert output =~ "def py_main"
      assert output =~ "TranslatedCode.py_main()"
    end

    test "output compiles and runs with zero compiler warnings via transpile_and_run" do
      {_source, value, stdout, diagnostics} =
        TranspileHelpers.transpile_and_run(%{"_type" => "Module", "body" => []})

      # py_main on empty Module returns nil and emits nothing on stdout.
      assert value == nil
      assert stdout == ""

      assert diagnostics == [],
             "generated module produced unexpected diagnostics: " <> inspect(diagnostics)
    end
  end
end
