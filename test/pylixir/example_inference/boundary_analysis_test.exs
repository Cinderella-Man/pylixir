defmodule Pylixir.ExampleInference.BoundaryAnalysisTest do
  use ExUnit.Case, async: true

  alias Pylixir.ExampleInference.BoundaryAnalysis

  defp parse(source) do
    Pylixir.python_ast(source)["body"]
  end

  defp python_available? do
    case System.cmd("python3.14", ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.starts_with?(out, "Python 3.14")
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  describe "analyze/1" do
    test "detects input() on RHS at Assign site" do
      if python_available?() do
        body = parse("n = int(input())\n")
        assert %{1 => "n"} = BoundaryAnalysis.analyze(body)
      end
    end

    test "detects input() nested inside list-comp on RHS" do
      if python_available?() do
        body = parse("xs = [int(x) for x in input().split()]\n")
        assert %{1 => "xs"} = BoundaryAnalysis.analyze(body)
      end
    end

    test "detects sys.stdin.readline()" do
      if python_available?() do
        body = parse("import sys\ndata = sys.stdin.readline()\n")
        assert BoundaryAnalysis.analyze(body) == %{2 => "data"}
      end
    end

    test "detects sys.argv subscript" do
      if python_available?() do
        body = parse("import sys\narg = sys.argv\n")
        assert BoundaryAnalysis.analyze(body) == %{2 => "arg"}
      end
    end

    test "skips Assign without input() reference" do
      if python_available?() do
        body = parse("x = 5\ny = x + 1\n")
        assert BoundaryAnalysis.analyze(body) == %{}
      end
    end

    test "skips tuple-LHS destructuring (resolution: seed-only, no guard)" do
      if python_available?() do
        body = parse("a, b = map(int, input().split())\n")
        assert BoundaryAnalysis.analyze(body) == %{}
      end
    end
  end
end
