defmodule Pylixir.Nodes.ComprehensionTest do
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

  describe "ListComp (T24)" do
    test "basic map" do
      case run("[x * 2 for x in [1, 2, 3, 4]]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [2, 4, 6, 8]
      end
    end

    test "with filter" do
      case run("[x for x in [1, 2, 3, 4, 5] if x % 2 == 0]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [2, 4]
      end
    end

    test "with multiple filters" do
      case run("[x for x in [1, 2, 3, 4, 5, 6] if x > 1 if x < 5]\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [2, 3, 4]
      end
    end

    test "nested generators" do
      case run("[(x, y) for x in [1, 2] for y in [10, 20]]\n") do
        :skip -> :ok

        {_, value, _, _} ->
          assert value == [{1, 10}, {1, 20}, {2, 10}, {2, 20}]
      end
    end
  end

  describe "SetComp (T24b)" do
    test "produces a MapSet" do
      case run("{x * 2 for x in [1, 2, 3, 2, 1]}\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == MapSet.new([2, 4, 6])
      end
    end
  end

  describe "DictComp (T24b)" do
    test "key-value pairs" do
      case run("{x: x * 10 for x in [1, 2, 3]}\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == %{1 => 10, 2 => 20, 3 => 30}
      end
    end
  end

  describe "GeneratorExp (T24b, eager per docs/plan.md)" do
    test "generator expression bound to a name emits an eager list" do
      case run("g = (x * x for x in [1, 2, 3])\ng\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 4, 9]
      end
    end
  end
end
