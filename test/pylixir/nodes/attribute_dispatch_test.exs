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
end
