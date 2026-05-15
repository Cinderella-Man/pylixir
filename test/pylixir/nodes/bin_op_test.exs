defmodule Pylixir.Nodes.BinOpTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp list_node(elts), do: %{"_type" => "List", "elts" => elts}
  defp op(name), do: %{"_type" => name}
  defp binop(op_name, left, right),
    do: %{"_type" => "BinOp", "op" => op(op_name), "left" => left, "right" => right}

  defp module_with(stmt), do: %{"_type" => "Module", "body" => [stmt]}

  describe "AST shape — T10 arithmetic ops" do
    test "Add emits py_add(left, right)" do
      {ast, _} = Converter.convert(binop("Add", const(1), const(2)), Context.new())
      assert ast == {:py_add, [], [1, 2]}
    end

    test "Sub emits a direct minus (no helper — RFC §6 no dispatch for Sub)" do
      {ast, _} = Converter.convert(binop("Sub", const(5), const(3)), Context.new())
      assert ast == {:-, [], [5, 3]}
    end

    test "Mult emits py_mult(left, right)" do
      {ast, _} = Converter.convert(binop("Mult", const(2), const(3)), Context.new())
      assert ast == {:py_mult, [], [2, 3]}
    end

    test "Div emits a direct slash (Python `/` is float div, same as Elixir)" do
      {ast, _} = Converter.convert(binop("Div", const(10), const(4)), Context.new())
      assert ast == {:/, [], [10, 4]}
    end

    test "Pow emits py_pow(left, right)" do
      {ast, _} = Converter.convert(binop("Pow", const(2), const(3)), Context.new())
      assert ast == {:py_pow, [], [2, 3]}
    end
  end

  describe "AST shape — unsupported operators (T11/T12 territory)" do
    test "FloorDiv raises (T11)" do
      assert_raise UnsupportedNodeError, ~r/FloorDiv/, fn ->
        Converter.convert(binop("FloorDiv", const(7), const(2)), Context.new())
      end
    end

    test "MatMult raises (T11 explicit rejection)" do
      assert_raise UnsupportedNodeError, ~r/MatMult/, fn ->
        Converter.convert(binop("MatMult", const(1), const(2)), Context.new())
      end
    end
  end

  describe "end-to-end — numeric semantics match Python" do
    test "1 + 2 == 3" do
      {_, value, _, diagnostics} =
        TranspileHelpers.transpile_and_run(module_with(binop("Add", const(1), const(2))))

      assert value == 3
      assert diagnostics == []
    end

    test "5 - 3 == 2" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("Sub", const(5), const(3))))

      assert value == 2
    end

    test "2 * 3 == 6" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("Mult", const(2), const(3))))

      assert value == 6
    end

    test "10 / 4 == 2.5 (Python `/` is float division)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("Div", const(10), const(4))))

      assert value == 2.5
    end

    test "2 ** 3 == 8 (Python `**` via py_pow uses Integer.pow for int^int)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("Pow", const(2), const(3))))

      assert value == 8
    end
  end

  describe "end-to-end — type-dispatch helpers cover the edge cases (RFC §6.8–6.11)" do
    test "string + string concatenates (RFC §6.8)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(binop("Add", const("hello, "), const("world")))
        )

      assert value == "hello, world"
    end

    test "list + list concatenates (RFC §6.8-adjacent)" do
      a = list_node([const(1), const(2)])
      b = list_node([const(3)])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(module_with(binop("Add", a, b)))

      assert value == [1, 2, 3]
    end

    test "string * int repeats (RFC §6.9)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("Mult", const("ab"), const(3))))

      assert value == "ababab"
    end

    test "True + True == 2 (RFC §6.11 boolean arithmetic)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("Add", const(true), const(true))))

      assert value == 2
    end

    test "Pow with float exponent uses :math.pow (RFC §6.10)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("Pow", const(4), const(0.5))))

      assert_in_delta value, 2.0, 1.0e-9
    end
  end
end
