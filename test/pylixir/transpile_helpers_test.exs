defmodule Pylixir.TranspileHelpersTest do
  use ExUnit.Case, async: true

  alias Pylixir.TranspileHelpers

  describe "run_source/1 — T04b acceptance via the hand-rolled source seam" do
    test "returns the expected four-tuple shape for a clean module" do
      source = """
      defmodule TranslatedCode do
        def py_main do
          IO.puts("hello")
          42
        end
      end

      TranslatedCode.py_main()
      """

      {out_source, value, stdout, diagnostics} = TranspileHelpers.run_source(source)

      assert out_source == source
      assert value == 42
      assert stdout =~ "hello"
      assert diagnostics == []
    end

    test "two calls in the same mix test do not warn about module redefinition" do
      source = """
      defmodule TranslatedCode do
        def py_main, do: :ok
      end

      TranslatedCode.py_main()
      """

      {_, _, _, diagnostics1} = TranspileHelpers.run_source(source)
      {_, _, _, diagnostics2} = TranspileHelpers.run_source(source)

      assert diagnostics1 == []
      assert diagnostics2 == []
    end

    test "diagnostics list is non-empty for code that produces a compile warning" do
      # An unused variable inside py_main forces the Elixir compiler to emit
      # a structured diagnostic. Guards against a helper bug that swallows
      # warnings — without this, T05's "zero warnings" acceptance would be
      # vacuously true.
      source = """
      defmodule TranslatedCode do
        def py_main do
          unused_local = 5
          :ok
        end
      end

      TranslatedCode.py_main()
      """

      {_, _, _, diagnostics} = TranspileHelpers.run_source(source)

      refute diagnostics == []

      assert Enum.any?(diagnostics, fn d ->
               (d[:message] || "") =~ "unused"
             end)
    end

    test "accepts a bare defmodule (no trailing call) and still invokes py_main" do
      source = """
      defmodule TranslatedCode do
        def py_main, do: :bare
      end
      """

      {_, value, _stdout, diagnostics} = TranspileHelpers.run_source(source)

      assert value == :bare
      assert diagnostics == []
    end

    test "raises a clear error if the source has no defmodule" do
      assert_raise ArgumentError, ~r/defmodule/, fn ->
        TranspileHelpers.run_source(":ok\n")
      end
    end
  end

  describe "transpile_and_run/1 — end-to-end (waits on T05's Module clause)" do
    test "currently raises UnsupportedNodeError since T05 hasn't shipped" do
      # When T05 lands, replace this with an end-to-end success test.
      assert_raise Pylixir.UnsupportedNodeError, ~r/Module/, fn ->
        TranspileHelpers.transpile_and_run(%{"_type" => "Module", "body" => []})
      end
    end
  end
end
