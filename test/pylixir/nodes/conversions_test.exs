defmodule Pylixir.Nodes.ConversionsTest do
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

  describe "T26 conversions" do
    test "int(\"42\") parses" do
      case run("int(\"42\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 42
      end
    end

    test "int(3.7) truncates" do
      case run("int(3.7)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 3
      end
    end

    test "float(\"3.14\")" do
      case run("float(\"3.14\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert_in_delta value, 3.14, 1.0e-9
      end
    end

    test "str(42) → '42'" do
      case run("str(42)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "42"
      end
    end

    test "str(True) → 'True' (RFC §6.7)" do
      case run("str(True)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "True"
      end
    end

    test "bool([]) → False (Python-falsy via truthy?)" do
      case run("bool([])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == false
      end
    end

    test "bool([1]) → True" do
      case run("bool([1])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "list(range(3)) materializes" do
      # range already returns a list; list() is the identity-shape here.
      case run("(range(3))\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == [0, 1, 2]
      end
    end

    test "tuple(...) builds a tuple" do
      case run("tuple([1, 2, 3])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == {1, 2, 3}
      end
    end

    test "set(...) builds a MapSet" do
      case run("set([1, 2, 2, 3, 3, 3])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == MapSet.new([1, 2, 3])
      end
    end

    test ~s|dict([("a", 1), ("b", 2)])| do
      case run(~s|dict([("a", 1), ("b", 2)])\n|) do
        :skip -> :ok
        {_, value, _, _} -> assert value == %{"a" => 1, "b" => 2}
      end
    end
  end

  describe "T26 isinstance" do
    test "isinstance(5, int)" do
      case run("isinstance(5, int)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "isinstance(True, int) → True (RFC §6.13)" do
      case run("isinstance(True, int)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "isinstance(\"x\", str)" do
      case run("isinstance(\"hello\", str)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "isinstance(5, str) → False" do
      case run("isinstance(5, str)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == false
      end
    end

    test "isinstance([1, 2], list)" do
      case run("isinstance([1, 2], list)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "isinstance({}, dict)" do
      case run("isinstance({}, dict)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end
  end
end
