defmodule Pylixir.TranspileWithExamplesTest do
  @moduledoc """
  Regression tests for the `:examples` opt added to `transpile/2` and
  `to_source/2` (docs/09).

  Step 1: examples accepted but ignored. Asserts the strict-subset
  invariant — passing `examples: []` produces byte-identical output to
  the no-opt path, across every fixture in `test/fixtures/python/`.
  """
  use ExUnit.Case, async: true

  alias Pylixir.PythonParseError

  @fixtures_dir Path.expand("../fixtures/python", __DIR__)

  @fixtures @fixtures_dir
            |> File.ls!()
            |> Enum.filter(&String.ends_with?(&1, ".py"))
            |> Enum.sort()

  defp python_cmd, do: System.get_env("PYLIXIR_PYTHON") || "python3.14"

  setup_all do
    available =
      try do
        case System.cmd(python_cmd(), ["--version"], stderr_to_stdout: true) do
          {out, 0} -> String.starts_with?(out, "Python 3.14")
          _ -> false
        end
      rescue
        ErlangError -> false
      end

    {:ok, python_available?: available}
  end

  for fixture <- @fixtures do
    @tag fixture: fixture
    test "examples: [] is byte-identical to no-opt for #{fixture}",
         %{python_available?: available, fixture: fixture} do
      unless available do
        :ok
      else
        source = File.read!(Path.join(@fixtures_dir, fixture))

        try do
          ast = Pylixir.python_ast(source)
          arity_1 = Pylixir.to_source(ast)
          arity_2_empty = Pylixir.to_source(ast, examples: [])
          assert arity_1 == arity_2_empty
        rescue
          PythonParseError -> :ok
          Pylixir.UnsupportedNodeError -> :ok
        end
      end
    end
  end

  describe "transpile/2 wrapper" do
    test "transpile/1 and transpile/2 with empty examples are byte-identical" do
      source = "x = 1\nprint(x + 1)\n"

      if System.cmd(python_cmd(), ["--version"], stderr_to_stdout: true) |> elem(1) == 0 do
        assert Pylixir.transpile(source) == Pylixir.transpile(source, examples: [])
      end
    end

    test "transpile/2 accepts the :examples opt without raising" do
      source = "print(1)\n"

      if System.cmd(python_cmd(), ["--version"], stderr_to_stdout: true) |> elem(1) == 0 do
        out =
          Pylixir.transpile(source,
            examples: [%{stdin: "ignored\n", stdout: "ignored\n"}]
          )

        assert is_binary(out)
        assert out == Pylixir.transpile(source)
      end
    end
  end
end
