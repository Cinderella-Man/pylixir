defmodule Pylixir.Nodes.SubscriptTest do
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

  describe "non-slice Subscript via py_getitem" do
    test "list index" do
      case run("xs = [10, 20, 30]\nxs[1]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 20
      end
    end

    test "negative list index (Python wraps from end)" do
      case run("xs = [10, 20, 30]\nxs[-1]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 30
      end
    end

    test "dict key lookup" do
      case run(~s(d = {"a": 1, "b": 2}\nd["b"]\n)) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 2
      end
    end

    test "tuple index" do
      case run("t = (10, 20, 30)\nt[1]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 20
      end
    end

    test "string index returns single character" do
      case run(~s(s = "hello"\ns[1]\n)) do
        :skip -> :ok
        {_, value, _, _} -> assert value == "e"
      end
    end

    test "nested subscript: matrix[i][j]" do
      case run("m = [[1, 2], [3, 4]]\nm[1][0]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 3
      end
    end
  end
end
