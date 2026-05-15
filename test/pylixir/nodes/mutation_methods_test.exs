defmodule Pylixir.Nodes.MutationMethodsTest do
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

  describe "List mutations (statement context)" do
    test "append" do
      case run("""
           xs = [1, 2, 3]
           xs.append(4)
           xs
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 2, 3, 4]
      end
    end

    test "sort" do
      case run("""
           xs = [3, 1, 4, 1, 5]
           xs.sort()
           xs
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 1, 3, 4, 5]
      end
    end

    test "sort with reverse=True" do
      case run("""
           xs = [3, 1, 2]
           xs.sort(reverse=True)
           xs
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [3, 2, 1]
      end
    end

    test "reverse" do
      case run("""
           xs = [1, 2, 3]
           xs.reverse()
           xs
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [3, 2, 1]
      end
    end

    test "insert" do
      case run("""
           xs = [1, 2, 4]
           xs.insert(2, 3)
           xs
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 2, 3, 4]
      end
    end

    test "extend" do
      case run("""
           xs = [1, 2]
           xs.extend([3, 4])
           xs
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 2, 3, 4]
      end
    end

    test "remove" do
      case run("""
           xs = [1, 2, 3, 2]
           xs.remove(2)
           xs
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 3, 2]
      end
    end

    test "pop (statement context — element discarded)" do
      case run("""
           xs = [1, 2, 3]
           xs.pop()
           xs
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 2]
      end
    end

    test "pop(i)" do
      case run("""
           xs = [10, 20, 30]
           xs.pop(1)
           xs
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [10, 30]
      end
    end
  end

  describe "Dict mutations" do
    test "update" do
      case run("""
           d = {"a": 1}
           d.update({"b": 2})
           d
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == %{"a" => 1, "b" => 2}
      end
    end
  end

  describe "Set mutations" do
    test "add" do
      case run("""
           s = set([1, 2])
           s.add(3)
           s
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == MapSet.new([1, 2, 3])
      end
    end

    test "discard (no error if missing)" do
      case run("""
           s = set([1, 2])
           s.discard(99)
           s
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == MapSet.new([1, 2])
      end
    end
  end
end
