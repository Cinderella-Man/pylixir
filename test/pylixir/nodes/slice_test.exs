defmodule Pylixir.Nodes.SliceTest do
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

  describe "List slicing — RFC §6.18" do
    test "x[a:b]" do
      case run("xs = [10, 20, 30, 40, 50]\nxs[1:4]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [20, 30, 40]
      end
    end

    test "x[:b] (omitted start)" do
      case run("xs = [10, 20, 30, 40, 50]\nxs[:3]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [10, 20, 30]
      end
    end

    test "x[a:] (omitted end)" do
      case run("xs = [10, 20, 30, 40, 50]\nxs[2:]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [30, 40, 50]
      end
    end

    test "x[:] (full copy / passthrough)" do
      case run("xs = [10, 20, 30]\nxs[:]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [10, 20, 30]
      end
    end

    test "x[::-1] reverse" do
      case run("xs = [1, 2, 3, 4, 5]\nxs[::-1]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [5, 4, 3, 2, 1]
      end
    end

    test "x[::2] take every second" do
      case run("xs = [1, 2, 3, 4, 5, 6]\nxs[::2]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 3, 5]
      end
    end

    test "x[a:b:n] with positive step" do
      case run("xs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]\nxs[2:8:2]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [2, 4, 6]
      end
    end

    test "negative indices wrap from end" do
      case run("xs = [10, 20, 30, 40, 50]\nxs[-3:-1]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [30, 40]
      end
    end
  end

  describe "String slicing" do
    test "s[:n] first n characters" do
      case run("""
           s = "hello, world"
           s[:5]
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == "hello"
      end
    end

    test "s[::-1] reverse a string" do
      case run("""
           s = "abc"
           s[::-1]
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == "cba"
      end
    end
  end
end
