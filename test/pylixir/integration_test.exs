defmodule Pylixir.IntegrationTest do
  @moduledoc """
  End-to-end tests that shell out to `python3.14` to parse REAL Python
  source, feed the resulting AST through the full Pylixir pipeline, then
  compile and evaluate the generated Elixir. These tests assert that our
  assumptions about Python 3.14's AST shape match reality.

  Skipped when no Python 3.14.x is available on PATH (or via PYLIXIR_PYTHON).
  """
  use ExUnit.Case, async: true

  alias Pylixir.{PythonParseError, TranspileHelpers}

  defp python_available? do
    python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

    case System.cmd(python, ["--version"], stderr_to_stdout: true) do
      {output, 0} -> String.starts_with?(output, "Python 3.14")
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  defp run_python(source) do
    if python_available?() do
      elixir_source = Pylixir.transpile(source)
      TranspileHelpers.run_source(elixir_source)
    else
      :skip
    end
  end

  describe "Constants & Names (T06/T07)" do
    test "bare integer literal at module top" do
      case run_python("42\n") do
        :skip -> :ok
        {_, value, _, diagnostics} ->
          assert value == 42
          assert diagnostics == []
      end
    end

    test "string literal" do
      case run_python(~S(
"hello, world"
)) do
        :skip -> :ok
        {_, value, _, _} -> assert value == "hello, world"
      end
    end

    test "None literal" do
      case run_python("None\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == nil
      end
    end

    test "True / False literals" do
      case run_python("True\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end
  end

  describe "Operators (T09–T12)" do
    test "1 + 2 * 3 — precedence preserved through py_add and py_mult" do
      case run_python("1 + 2 * 3\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 7
      end
    end

    test "string concatenation through py_add" do
      case run_python(~S("hello, " + "world"
)) do
        :skip -> :ok
        {_, value, _, _} -> assert value == "hello, world"
      end
    end

    test "boolean arithmetic: True + True == 2" do
      case run_python("True + True\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 2
      end
    end

    test "floor division: -7 // 2 == -4 (Python floor, not truncate)" do
      case run_python("-7 // 2\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == -4
      end
    end

    test "modulo: -7 % 2 == 1 (Python floor-modulo)" do
      case run_python("-7 % 2\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 1
      end
    end

    test "power: 2 ** 10 == 1024" do
      case run_python("2 ** 10\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 1024
      end
    end

    test "unary not on Python-falsy []" do
      case run_python("not []\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "chained comparison: 1 < 5 < 10" do
      case run_python("1 < 5 < 10\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "membership: 3 in [1, 2, 3]" do
      case run_python("3 in [1, 2, 3]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "is None comparison" do
      case run_python("None is None\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end
  end

  describe "Literal containers (T08)" do
    test "list literal" do
      case run_python("[1, 2, 3]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 2, 3]
      end
    end

    test "tuple literal" do
      case run_python("(1, 2, 3)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == {1, 2, 3}
      end
    end

    test "dict literal" do
      case run_python(~S({"a": 1, "b": 2}
)) do
        :skip -> :ok
        {_, value, _, _} -> assert value == %{"a" => 1, "b" => 2}
      end
    end

    test "nested literals" do
      case run_python("[(1, 2), (3, 4)]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [{1, 2}, {3, 4}]
      end
    end
  end

  describe "Assign / AugAssign (T13/T14)" do
    test "x = 1; y = 2; x + y" do
      case run_python("x = 1\ny = 2\nx + y\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 3
      end
    end

    test "tuple swap: a, b = b, a — mutation scan must demote a/b from module attrs" do
      case run_python("a = 1\nb = 2\na, b = b, a\n(a, b)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == {2, 1}
      end
    end

    test "AugAssign on a list element: xs[1] *= 10" do
      case run_python("xs = [2, 3, 4]\nxs[1] *= 10\nxs\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [2, 30, 4]
      end
    end

    test "Compound: AugAssign accumulation" do
      case run_python("total = 0\ntotal += 1\ntotal += 2\ntotal += 3\ntotal\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 6
      end
    end
  end

  describe "If / IfExp (T15)" do
    test "ternary IfExp" do
      case run_python(~S('big' if 10 > 5 else 'small'
)) do
        :skip -> :ok
        {_, value, _, _} -> assert value == "big"
      end
    end

    test "if-statement evaluated as last expression of module" do
      # The if statement's value (the body's last expr) is what py_main
      # returns.
      case run_python("x = 5\nif x > 3:\n    100\nelse:\n    -1\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 100
      end
    end

    test "elif chain returns the matching arm's value" do
      source = """
      x = 0
      if x < 0:
          -1
      elif x == 0:
          0
      else:
          1
      """

      case run_python(source) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 0
      end
    end

    test "elif chain WITHOUT a terminal else returns nil when nothing matches" do
      source = """
      x = 99
      if x < 0:
          -1
      elif x == 0:
          0
      """

      case run_python(source) do
        :skip -> :ok
        {_, value, _, _} -> assert value == nil
      end
    end
  end

  describe "Module-level constants & module-attribute promotion" do
    test "PI = 3.14 is promoted to @var_PI" do
      source = """
      PI = 3.14
      PI
      """

      if python_available?() do
        elixir_source = Pylixir.transpile(source)
        assert elixir_source =~ "@var_PI 3.14"
      end
    end

    test "DATA = [1, 2, 3] (mutation-free) is promoted, value is the literal" do
      source = """
      DATA = [10, 20, 30]
      DATA
      """

      case run_python(source) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [10, 20, 30]
      end
    end
  end

  describe "__name__ idiom" do
    test "__name__ at module level resolves to \"__main__\"" do
      case run_python("__name__\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "__main__"
      end
    end

    test "the classic guard: __name__ == \"__main__\" is true" do
      source = ~S(
result = 0
if __name__ == "__main__":
    100
else:
    -1
)

      case run_python(source) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 100
      end
    end
  end

  describe "Unsupported nodes raise" do
    test "f-string raises UnsupportedNodeError" do
      if python_available?() do
        assert_raise Pylixir.UnsupportedNodeError, fn ->
          Pylixir.transpile(~s(name = "world"\nf"hello, {name}"\n))
        end
      end
    end

    test "class definition raises" do
      if python_available?() do
        assert_raise Pylixir.UnsupportedNodeError, fn ->
          Pylixir.transpile("class A:\n    pass\n")
        end
      end
    end
  end

  describe "Python parse errors surface cleanly" do
    test "SyntaxError raises PythonParseError, not Jason.DecodeError" do
      if python_available?() do
        err =
          assert_raise PythonParseError, fn ->
            Pylixir.transpile("def )\n")
          end

        assert err.message =~ "syntax" or err.message =~ "invalid" or err.lineno != nil
      end
    end
  end
end
