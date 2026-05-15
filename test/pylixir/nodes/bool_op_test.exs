defmodule Pylixir.Nodes.BoolOpTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp op(name), do: %{"_type" => name}

  defp bool_op(op_name, values),
    do: %{"_type" => "BoolOp", "op" => op(op_name), "values" => values}

  defp module_with(stmt), do: %{"_type" => "Module", "body" => [stmt]}

  describe "AST shape" do
    test "And of two values emits a single && pair" do
      {ast, _} = Converter.convert(bool_op("And", [const(1), const(2)]), Context.new())
      assert ast == {:&&, [], [1, 2]}
    end

    test "Or of two values emits a single || pair" do
      {ast, _} = Converter.convert(bool_op("Or", [const(true), const(false)]), Context.new())
      assert ast == {:||, [], [true, false]}
    end

    test "And of three values left-folds" do
      {ast, _} = Converter.convert(bool_op("And", [const(1), const(2), const(3)]), Context.new())
      assert ast == {:&&, [], [{:&&, [], [1, 2]}, 3]}
    end
  end

  describe "end-to-end — RFC §6.3 cases where Elixir && / || semantics agree with Python and/or" do
    test "And of two truthy values returns the last (1 and 2 == 2)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(bool_op("And", [const(1), const(2)])))

      assert value == 2
    end

    test "And short-circuits on nil/None" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(bool_op("And", [const(nil), const("never")]))
        )

      assert value == nil
    end

    test "Or short-circuits on nil/None (False or X → X when False maps to nil/false)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(bool_op("Or", [const(false), const("found")]))
        )

      assert value == "found"
    end

    # NOTE: `0 and X` and `"" or X` are documented divergences (RFC §6.3) —
    # Elixir's truthiness treats 0 and "" as truthy. Such cases are out of
    # scope for the MVP translation.
  end
end
