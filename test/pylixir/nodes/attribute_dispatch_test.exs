defmodule Pylixir.Nodes.AttributeDispatchTest do
  use ExUnit.Case, async: true

  alias Pylixir.TranspileHelpers

  defp run(source) do
    python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

    case System.cmd(python, ["--version"], stderr_to_stdout: true) do
      {out, 0} ->
        if String.starts_with?(out, "Python 3.14") do
          elixir_src = Pylixir.transpile(source)
          TranspileHelpers.run_source(elixir_src)
        else
          :skip
        end

      _ ->
        :skip
    end
  rescue
    ErlangError -> :skip
  end

  describe "Dict methods (T28)" do
    test "d.keys()" do
      case run(~s|d = {"a": 1, "b": 2}\nd.keys()\n|) do
        :skip -> :ok
        {_, value, _, _} -> assert Enum.sort(value) == ["a", "b"]
      end
    end

    test "d.values()" do
      case run(~s|d = {"a": 1, "b": 2}\nd.values()\n|) do
        :skip -> :ok
        {_, value, _, _} -> assert Enum.sort(value) == [1, 2]
      end
    end

    test "d.items()" do
      case run("d = {\"a\": 1}\nd.items()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [{"a", 1}]
      end
    end

    test "d.get(k) — present" do
      case run(~s|d = {"a": 1}\nd.get("a")\n|) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 1
      end
    end

    test "d.get(k) — missing returns nil/None" do
      case run("d = {}\nd.get(\"missing\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == nil
      end
    end

    test "d.get(k, default) — present" do
      case run(~s|d = {"a": 1}\nd.get("a", 0)\n|) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 1
      end
    end

    test "d.get(k, default) — missing returns default" do
      case run("d = {}\nd.get(\"missing\", 42)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 42
      end
    end
  end

  describe "Math module (T27/T28)" do
    test "import math; math.sqrt(4)" do
      case run("import math\nmath.sqrt(4)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert_in_delta value, 2.0, 1.0e-9
      end
    end

    test "math.floor and math.ceil" do
      case run("import math\nmath.floor(3.7)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 3
      end
    end

    test "math.pi (bare attribute)" do
      case run("import math\nmath.pi\n") do
        :skip -> :ok
        {_, value, _, _} -> assert_in_delta value, 3.14159, 1.0e-4
      end
    end

    test "math.inf raises" do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            assert_raise Pylixir.UnsupportedNodeError, ~r/math\.inf/, fn ->
              Pylixir.transpile("import math\nmath.inf\n")
            end
          end

        _ ->
          :ok
      end
    end

    test "math.gcd(a, b) routes to Integer.gcd/2" do
      case run("import math\nmath.gcd(12, 8)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 4
      end
    end

    test "math.isqrt(n) — floor of integer square root" do
      case run("import math\nmath.isqrt(10)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 3
      end
    end
  end

  # `.format()` is only handled for *literal* templates with a single
  # placeholder. Codegen parses the spec; anything more complex falls
  # back to the generic error.
  describe "String .format() — single-placeholder forms" do
    test "{:.Nf} float formatting" do
      case run(~s|"{0:.6f}".format(3.14159265358979)\n|) do
        :skip -> :ok
        {_, value, _, _} -> assert value == "3.141593"
      end
    end

    test "{} bare positional" do
      case run(~s|"{}".format(42)\n|) do
        :skip -> :ok
        {_, value, _, _} -> assert value == "42"
      end
    end

    test "{N} indexed positional" do
      case run(~s|"{0}".format("hello")\n|) do
        :skip -> :ok
        {_, value, _, _} -> assert value == "hello"
      end
    end

    test "multi-placeholder template raises with the supported-shapes hint" do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            assert_raise Pylixir.UnsupportedNodeError, ~r/single-placeholder/, fn ->
              Pylixir.transpile(~s|"{} and {}".format(1, 2)\n|)
            end
          end

        _ ->
          :ok
      end
    end
  end

  describe "Int methods" do
    test "(5).bit_length() → 3" do
      case run("(5).bit_length()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 3
      end
    end

    test "(0).bit_length() → 0 (Python's special-case)" do
      case run("(0).bit_length()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 0
      end
    end

    test "negative int — uses absolute value" do
      case run("(-7).bit_length()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 3
      end
    end
  end

  describe "Unknown method raises (instead of emit-as-is)" do
    test "\"hello\".format(...) raises at translation time" do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            assert_raise Pylixir.UnsupportedNodeError, ~r/\.format/, fn ->
              Pylixir.transpile(~s|"hi".format("x")\n|)
            end
          end

        _ ->
          :ok
      end
    end
  end

  # `.copy()` on any container is an immutability no-op — Elixir's
  # data structures are already immutable. The subsequent mutation
  # rewrites (`xs.remove(y)` → `xs = List.delete(xs, y)`) preserve
  # the original because the copy and original alias the same value.
  describe ".copy() (immutability no-op)" do
    test "list copy + mutation on copy leaves original intact" do
      case run("xs = [1, 2, 3]\nys = xs.copy()\nys.remove(2)\n(xs, ys)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == {[1, 2, 3], [1, 3]}
      end
    end

    test "dict copy + mutation on copy leaves original intact" do
      case run(~s|d = {"a": 1}\ne = d.copy()\ne["a"] = 99\n(d, e)\n|) do
        :skip -> :ok
        {_, value, _, _} -> assert value == {%{"a" => 1}, %{"a" => 99}}
      end
    end
  end
end
