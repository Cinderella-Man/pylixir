defmodule Pylixir.Nodes.UnaryOpTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp op(name), do: %{"_type" => name}
  defp unary(op_name, operand), do: %{"_type" => "UnaryOp", "op" => op(op_name), "operand" => operand}

  defp module_with(stmt),
    do: %{"_type" => "Module", "body" => [stmt]}

  describe "AST shape" do
    test "UAdd is a no-op — operand passes through" do
      {ast, _} = Converter.convert(unary("UAdd", const(5)), Context.new())
      assert ast == 5
    end

    test "USub emits unary minus" do
      {ast, _} = Converter.convert(unary("USub", const(5)), Context.new())
      assert ast == {:-, [], [5]}
    end

    test "Invert emits Bitwise.bnot (fully-qualified — no import Bitwise)" do
      {ast, _} = Converter.convert(unary("Invert", const(5)), Context.new())
      assert ast == {{:., [], [{:__aliases__, [], [:Bitwise]}, :bnot]}, [], [5]}
    end

    test "Not wraps the operand in truthy? before negating" do
      {ast, _} = Converter.convert(unary("Not", const(true)), Context.new())
      assert ast == {:!, [], [{:truthy?, [], [true]}]}
    end

    test "unsupported unary op raises with the op name in node_type" do
      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(
            %{
              "_type" => "UnaryOp",
              "op" => op("MadeUpOp"),
              "operand" => const(1),
              "lineno" => 2,
              "col_offset" => 0
            },
            Context.new()
          )
        end

      assert err.node_type == "MadeUpOp"
      assert err.lineno == 2
    end
  end

  describe "end-to-end via transpile_and_run" do
    test "USub of an integer evaluates to its negation" do
      {_, value, _, diagnostics} =
        TranspileHelpers.transpile_and_run(module_with(unary("USub", const(7))))

      assert value == -7
      assert diagnostics == []
    end

    test "Invert evaluates via Bitwise.bnot (Python ~5 == -6)" do
      {_, value, _, diagnostics} =
        TranspileHelpers.transpile_and_run(module_with(unary("Invert", const(5))))

      assert value == -6
      assert diagnostics == []
    end

    test "Not of a Python-truthy value yields false" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(unary("Not", const(1))))

      assert value == false
    end

    test "Not of a Python-falsy value yields true (empty list semantics)" do
      empty_list = %{"_type" => "List", "elts" => []}

      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(unary("Not", empty_list)))

      assert value == true
    end

    test "UAdd is structurally a no-op end-to-end" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(unary("UAdd", const(42))))

      assert value == 42
    end
  end
end
