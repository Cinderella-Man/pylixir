defmodule Pylixir.Stdlib.SysTest do
  use ExUnit.Case, async: true

  alias Pylixir.Stdlib.Sys

  describe "attribute/2" do
    test "sys.maxsize → 64-bit signed max literal" do
      assert Sys.attribute(["maxsize"], %{}) == {:ok, 9_223_372_036_854_775_807}
    end

    test "sys.argv → System.argv() call" do
      assert {:ok, ast} = Sys.attribute(["argv"], %{})
      # AST shape: a remote call with no args. Matching loosely so
      # cosmetic AST shifts don't break this — the call site is what
      # matters.
      assert match?({{:., _, [{:__aliases__, _, [:System]}, :argv]}, _, []}, ast)
    end

    test "bare sys.stdin lowers to IO.stream(:stdio, :line) — supports `for line in sys.stdin`" do
      assert {:ok, ast} = Sys.attribute(["stdin"], %{})
      rendered = Macro.to_string(ast)
      assert rendered =~ "IO.stream"
      assert rendered =~ ":stdio"
      assert rendered =~ ":line"
    end

    test "unknown attribute returns :no_clause" do
      assert Sys.attribute(["nosuchattr"], %{}) == :no_clause
      assert Sys.attribute(["deeply", "nested", "name"], %{}) == :no_clause
    end

    test "sys.stdin.read (bare attribute) lowers to a zero-arg lambda" do
      assert {:ok, ast} = Sys.attribute(["stdin", "read"], %{})
      assert match?({:fn, [], [{:->, [], [[], {:py_stdin_read, [], []}]}]}, ast)
    end

    test "sys.stdin.readline (bare attribute) lowers to a zero-arg lambda" do
      assert {:ok, ast} = Sys.attribute(["stdin", "readline"], %{})
      assert match?({:fn, [], [{:->, [], [[], {:py_stdin_readline, [], []}]}]}, ast)
    end
  end

  describe "call/4" do
    test "sys.exit() throws {:pylixir_exit, 0} — same shape as the `exit` builtin" do
      assert Sys.call(["exit"], [], %{}, %{}) == {:ok, {:throw, [], [{:pylixir_exit, 0}]}}
    end

    test "sys.exit(code) carries the code through the throw" do
      code_ast = {:n, [], nil}

      assert Sys.call(["exit"], [code_ast], %{}, %{}) ==
               {:ok, {:throw, [], [{:pylixir_exit, code_ast}]}}
    end

    test "sys.stdin.read() lowers to a bare py_stdin_read call (helper from RuntimeHelpers)" do
      assert Sys.call(["stdin", "read"], [], %{}, %{}) == {:ok, {:py_stdin_read, [], []}}
    end

    test "sys.stdin.readline() lowers to a bare py_stdin_readline call" do
      assert Sys.call(["stdin", "readline"], [], %{}, %{}) ==
               {:ok, {:py_stdin_readline, [], []}}
    end

    test "sys.stdout.write(s) lowers to IO.write(s)" do
      s_ast = "hi"
      assert {:ok, ast} = Sys.call(["stdout", "write"], [s_ast], %{}, %{})
      assert match?({{:., _, [{:__aliases__, _, [:IO]}, :write]}, _, ["hi"]}, ast)
    end

    test "unknown call path returns :no_clause" do
      assert Sys.call(["nosuch"], [], %{}, %{}) == :no_clause
      assert Sys.call(["stdin", "no_such_method"], [], %{}, %{}) == :no_clause
    end
  end
end
