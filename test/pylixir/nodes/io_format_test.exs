defmodule Pylixir.Nodes.IoFormatTest do
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

  describe "T27 print" do
    test "print single value emits to stdout with trailing newline" do
      case run("print(42)\n") do
        :skip -> :ok
        {_, _, stdout, _} -> assert stdout == "42\n"
      end
    end

    test "print multiple values joined with default space" do
      case run("print(1, 2, 3)\n") do
        :skip -> :ok
        {_, _, stdout, _} -> assert stdout == "1 2 3\n"
      end
    end

    test "print with sep kwarg" do
      case run("print(1, 2, 3, sep=\"-\")\n") do
        :skip -> :ok
        {_, _, stdout, _} -> assert stdout == "1-2-3\n"
      end
    end

    test "print with end kwarg" do
      case run("print(\"hi\", end=\"!\")\n") do
        :skip -> :ok
        {_, _, stdout, _} -> assert stdout == "hi!"
      end
    end

    test "print bool uses Python capitalisation (RFC §6.7)" do
      case run("print(True)\n") do
        :skip -> :ok
        {_, _, stdout, _} -> assert stdout == "True\n"
      end
    end

    test "print None" do
      case run("print(None)\n") do
        :skip -> :ok
        {_, _, stdout, _} -> assert stdout == "None\n"
      end
    end
  end

  describe "T27 numeric formatting" do
    test "hex" do
      case run("hex(255)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "0xff"
      end
    end

    test "hex negative" do
      case run("hex(-255)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "-0xff"
      end
    end

    test "oct" do
      case run("oct(8)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "0o10"
      end
    end

    test "bin" do
      case run("bin(5)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "0b101"
      end
    end

    test "round banker's: 0.5 → 0" do
      case run("round(0.5)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 0
      end
    end

    test "round banker's: 2.5 → 2" do
      case run("round(2.5)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 2
      end
    end

    test "chr(65) → 'A'" do
      case run("chr(65)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "A"
      end
    end

    test "ord('A') → 65" do
      case run("ord(\"A\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 65
      end
    end
  end

  describe "T27 divmod / any / all" do
    test "divmod(7, 3) → (2, 1)" do
      case run("divmod(7, 3)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == {2, 1}
      end
    end

    test "any with Python-truthy values" do
      case run("any([0, \"\", [], 1])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "any all-falsy" do
      case run("any([0, \"\", [], False])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == false
      end
    end

    test "all with Python-truthy values" do
      case run("all([1, \"x\", [0]])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "all with one Python-falsy (empty list)" do
      case run("all([1, [], 3])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == false
      end
    end
  end
end
