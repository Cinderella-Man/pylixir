defmodule Pylixir.Nodes.LambdaTest do
  use ExUnit.Case, async: true

  alias Pylixir.TranspileHelpers

  describe "end-to-end via real Python 3.14" do
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

    test "Lambda as value bound to a name" do
      case run("""
           double = lambda x: x * 2
           double(21)
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 42
      end
    end

    test "Lambda with multiple args" do
      case run("""
           add = lambda a, b: a + b
           add(3, 4)
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 7
      end
    end

    test "Lambda with default arg raises (Elixir fn lacks defaults; T19 defp would work)" do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            assert_raise Pylixir.UnsupportedNodeError, ~r/default/, fn ->
              Pylixir.transpile(
                "greet = lambda name, prefix='Hi': prefix + ', ' + name\ngreet('x')\n"
              )
            end
          end

        _ ->
          :ok
      end
    end

    test "nested non-recursive def inside an outer def" do
      case run("""
           def outer(x):
               def helper(y):
                   return y * 2
               return helper(x) + 1
           outer(5)
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 11
      end
    end

    test "nested recursive def — self-passing transform" do
      case run("""
           def outer(n):
               def fact(k):
                   if k <= 1:
                       return 1
                   return k * fact(k - 1)
               return fact(n)
           outer(5)
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 120
      end
    end

    test "lambda used as inline argument (T28 territory — currently goes to as-is call)" do
      # Lambda being passed inline to a function-call argument is T28 router work.
      # Here we exercise it via a name-bound use to stay within current scope.
      case run("""
           square = lambda x: x * x
           xs = [1, 2, 3]
           total = 0
           for x in xs:
               total += square(x)
           total
           """) do
        :skip -> :ok
        {_, value, _, _} -> assert value == 14
      end
    end
  end
end
