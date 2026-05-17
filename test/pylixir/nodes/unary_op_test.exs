defmodule Pylixir.Nodes.UnaryOpTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp op(name), do: %{"_type" => name}

  defp unary(op_name, operand),
    do: %{"_type" => "UnaryOp", "op" => op(op_name), "operand" => operand}

  defp module_with(stmt),
    do: %{"_type" => "Module", "body" => [stmt]}

  describe "AST shape" do
    test "UAdd is a no-op — operand passes through" do
      {ast, _} = Converter.convert(unary("UAdd", const(5)), Context.new())
      assert ast == 5
    end

    test "USub on a numeric literal constant-folds to the negated literal — preserves IEEE-754 negative zero" do
      # `-5` folds to `-5`; `-0.0` folds to `-0.0`. Bool-coercion path
      # (where the operand isn't a number literal at codegen time)
      # still goes through `py_sub(0, x)` — see the next test.
      {ast, _} = Converter.convert(unary("USub", const(5)), Context.new())
      assert ast == -5

      {ast_f, _} = Converter.convert(unary("USub", const(0.0)), Context.new())
      assert ast_f === -0.0
    end

    test "USub on a non-literal operand emits py_sub(0, x) — handles bool→int coercion per RFC §6.11" do
      # `-some_name` lowers via `py_sub(0, x)` because `x` is an Elixir
      # AST node `{:some_name, [], nil}`, not an integer/float literal.
      name_node = %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Load"}}
      {ast, _} = Converter.convert(unary("USub", name_node), Context.new())
      assert ast == {:py_sub, [], [0, {:x, [], nil}]}
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
