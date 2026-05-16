defmodule Pylixir.Nodes.BuiltinsTest do
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

  describe "T25a — iteration shape primitives" do
    test "len of list" do
      case run("len([1, 2, 3, 4])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 4
      end
    end

    test "len of string" do
      case run("len(\"hello\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 5
      end
    end

    test "range(stop)" do
      case run("(range(5))\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [0, 1, 2, 3, 4]
      end
    end

    test "sorted/reversed" do
      case run("sorted([3, 1, 4, 1, 5, 9, 2, 6])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 1, 2, 3, 4, 5, 6, 9]
      end
    end

    test "sorted with reverse=True" do
      case run("sorted([3, 1, 2], reverse=True)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [3, 2, 1]
      end
    end

    test "reversed wraps a list" do
      case run("(reversed([1, 2, 3]))\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [3, 2, 1]
      end
    end

    test "enumerate yields (i, x) tuples (RFC §6.5 swap)" do
      case run("(enumerate(['a', 'b', 'c']))\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [{0, "a"}, {1, "b"}, {2, "c"}]
      end
    end

    test "enumerate with start kwarg" do
      case run("(enumerate(['a', 'b'], start=10))\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [{10, "a"}, {11, "b"}]
      end
    end

    test "zip two lists" do
      case run("(zip([1, 2, 3], ['a', 'b', 'c']))\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [{1, "a"}, {2, "b"}, {3, "c"}]
      end
    end
  end

  describe "T25b — aggregation + functional" do
    test "sum" do
      case run("sum([1, 2, 3, 4, 5])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 15
      end
    end

    test "min/max on a list (1-arg)" do
      case run("min([3, 1, 4, 1, 5, 9, 2, 6])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 1
      end
    end

    test "min/max variadic" do
      case run("max(1, 2, 3)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 3
      end
    end

    test "min with default kwarg" do
      case run("min([], default=42)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 42
      end
    end

    test "abs" do
      case run("abs(-7)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 7
      end
    end

    test "map composed with a lambda" do
      case run("""
           f = lambda x: x * 2
           (map(f, [1, 2, 3]))
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [2, 4, 6]
      end
    end

    test "filter composed with a lambda" do
      case run("""
           is_even = lambda x: x % 2 == 0
           (filter(is_even, [1, 2, 3, 4, 5]))
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [2, 4]
      end
    end
  end

  # Bare references to unary builtins must lower as unary lambdas
  # delegating to the same emit/3 clause used for direct calls — without
  # this, `map(int, xs)` and friends fall through to an undefined Elixir
  # variable. See lib/pylixir/builtins.ex `@unary_capturable`.
  describe "bare builtin references (unary capture)" do
    test "map(int, [...]) coerces decimal strings" do
      case run("(list(map(int, [\"1\", \"2\", \"3\", \"4\"])))\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 2, 3, 4]
      end
    end

    test "map(str, [...]) renders ints as strings" do
      case run("(list(map(str, [1, 2, 3])))\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == ["1", "2", "3"]
      end
    end

    test "map(abs, [...]) — bare unary helper" do
      case run("(list(map(abs, [-1, 2, -3])))\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [1, 2, 3]
      end
    end

    test "local binding shadows the builtin: `int = ...; map(int, ...)` uses the local" do
      # Python semantics: a local `int` shadows the builtin. Pylixir's
      # bare-Name converter must honour scope before falling through to
      # the builtin capture, otherwise this would call `py_int/1`.
      case run("""
           int = lambda x: x + 100
           (list(map(int, [1, 2, 3])))
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == [101, 102, 103]
      end
    end
  end
end
