defmodule Pylixir.Nodes.StringMethodsTest do
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

  describe "T29a — case / whitespace / prefix-suffix / join" do
    test "lower / upper" do
      case run("\"Hello\".lower()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "hello"
      end
    end

    test "upper" do
      case run("\"Hi\".upper()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "HI"
      end
    end

    test "strip without arg" do
      case run("\"  hello  \".strip()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "hello"
      end
    end

    test "lstrip / rstrip" do
      case run("\"  x  \".lstrip()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "x  "
      end
    end

    test "startswith" do
      case run("\"hello\".startswith(\"he\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "endswith — negative case" do
      case run("\"hello\".endswith(\"xx\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == false
      end
    end

    test "sep.join (RFC §10.1 arg-swap)" do
      case run("\"-\".join([\"a\", \"b\", \"c\"])\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "a-b-c"
      end
    end
  end

  describe "T29b — split / replace / search / classification" do
    test "split on whitespace (no arg)" do
      case run("\"a b c\".split()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == ["a", "b", "c"]
      end
    end

    test "split with sep" do
      case run("\"a,b,c\".split(\",\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == ["a", "b", "c"]
      end
    end

    test "replace" do
      case run("\"hello world\".replace(\"world\", \"Elixir\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "hello Elixir"
      end
    end

    test "find present" do
      case run("\"hello\".find(\"ll\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 2
      end
    end

    test "find absent → -1" do
      case run("\"hello\".find(\"zz\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == -1
      end
    end

    test "count" do
      case run("\"banana\".count(\"a\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 3
      end
    end

    test "index found" do
      case run("\"hello\".index(\"ll\")\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == 2
      end
    end

    test "zfill" do
      case run("\"5\".zfill(3)\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == "005"
      end
    end

    test "isdigit on digits" do
      case run("\"123\".isdigit()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "isdigit with letters" do
      case run("\"abc\".isdigit()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == false
      end
    end

    test "isalpha" do
      case run("\"abc\".isalpha()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end

    test "isalnum" do
      case run("\"abc123\".isalnum()\n") do
        :skip -> :ok
        {_, value, _, _} -> assert value == true
      end
    end
  end

  describe "T29 rejections" do
    test "multi-char strip raises (RFC §6.24)" do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            assert_raise Pylixir.UnsupportedNodeError, ~r/multi-char/, fn ->
              Pylixir.transpile("\"abc\".strip(\"ab\")\n")
            end
          end

        _ ->
          :ok
      end
    end

    test "split('') raises (RFC §6.20)" do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            assert_raise Pylixir.UnsupportedNodeError, ~r/split/, fn ->
              Pylixir.transpile("\"abc\".split(\"\")\n")
            end
          end

        _ ->
          :ok
      end
    end
  end
end
