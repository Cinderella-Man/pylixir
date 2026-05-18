defmodule Pylixir.Nodes.BinOpTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp list_node(elts), do: %{"_type" => "List", "elts" => elts}
  defp op(name), do: %{"_type" => name}
  defp unbound_name(id), do: %{"_type" => "Name", "id" => id}

  defp binop(op_name, left, right),
    do: %{"_type" => "BinOp", "op" => op(op_name), "left" => left, "right" => right}

  defp module_with(stmt), do: %{"_type" => "Module", "body" => [stmt]}

  describe "AST shape — T10 arithmetic ops" do
    # Specialization (PR 2) collapses int+int / int-int / int*int / int/int
    # to the direct Kernel op. When operand types are unknown, the
    # polymorphic helper still fires (see "polymorphic fallback" tests
    # below). Bool-tainted operands also fall through.

    test "Add on two int literals specializes to Kernel.+" do
      {ast, _} = Converter.convert(binop("Add", const(1), const(2)), Context.new())
      assert ast == {:+, [], [1, 2]}
    end

    test "Sub on two int literals specializes to Kernel.-" do
      {ast, _} = Converter.convert(binop("Sub", const(5), const(3)), Context.new())
      assert ast == {:-, [], [5, 3]}
    end

    test "Mult on two int literals specializes to Kernel.*" do
      {ast, _} = Converter.convert(binop("Mult", const(2), const(3)), Context.new())
      assert ast == {:*, [], [2, 3]}
    end

    test "Div on two int literals specializes to Kernel./ (Python 3 / = float)" do
      {ast, _} = Converter.convert(binop("Div", const(10), const(4)), Context.new())
      assert ast == {:/, [], [10, 4]}
    end

    test "Pow emits py_pow (no specialization yet)" do
      {ast, _} = Converter.convert(binop("Pow", const(2), const(3)), Context.new())
      assert ast == {:py_pow, [], [2, 3]}
    end
  end

  describe "polymorphic fallback — types unknown" do
    # An operand that resolves to :any (an unbound Name) keeps the
    # polymorphic helper. Proves PR 2 is purely additive.

    test "Add on unknown operands emits py_add" do
      {ast, _} = Converter.convert(binop("Add", unbound_name("x"), const(1)), Context.new())
      assert {:py_add, [], _} = ast
    end

    test "Mult on str literal × dynamic int emits py_mult (Q2-B)" do
      {ast, _} =
        Converter.convert(binop("Mult", const("ab"), unbound_name("n")), Context.new())

      assert {:py_mult, [], _} = ast
    end
  end

  describe "AST shape — T11 ops" do
    test "FloorDiv on two int literals specializes to Integer.floor_div" do
      # Both operands are `int_lit_nonneg` per `TypeInfer.infer_expr`,
      # which satisfies `TypeInfer.is_int?/1`. The bin_op_ast clause
      # specializes — `py_floor_div` only emitted when one operand is
      # `:any` / bool-tainted / non-int.
      {ast, _} = Converter.convert(binop("FloorDiv", const(7), const(2)), Context.new())
      assert ast == {{:., [], [{:__aliases__, [], [:Integer]}, :floor_div]}, [], [7, 2]}
    end

    test "Mod on two int literals specializes to Integer.mod" do
      # Same reasoning as FloorDiv. Avoids dragging `py_mod`'s polymorphic
      # binary-string clause + the entire percent-format helper cascade
      # into the output for an obviously-int operation.
      {ast, _} = Converter.convert(binop("Mod", const(7), const(2)), Context.new())
      assert ast == {{:., [], [{:__aliases__, [], [:Integer]}, :mod]}, [], [7, 2]}
    end

    test "LShift emits Bitwise.bsl (fully-qualified)" do
      {ast, _} = Converter.convert(binop("LShift", const(1), const(3)), Context.new())
      assert ast == {{:., [], [{:__aliases__, [], [:Bitwise]}, :bsl]}, [], [1, 3]}
    end

    test "RShift routes to Bitwise.bsr (no set-overload, direct call)" do
      {ast, _} = Converter.convert(binop("RShift", const(5), const(3)), Context.new())
      assert ast == {{:., [], [{:__aliases__, [], [:Bitwise]}, :bsr]}, [], [5, 3]}
    end

    test "BitOr / BitAnd / BitXor route through py_bor / py_band / py_bxor helpers" do
      # Python overloads `|` / `&` / `^` for set operations on top of
      # bitwise. The runtime helpers dispatch on operand type
      # (MapSet → set op; else → Bitwise.*).
      for {op_name, helper} <- [
            {"BitOr", :py_bor},
            {"BitAnd", :py_band},
            {"BitXor", :py_bxor}
          ] do
        {ast, _} = Converter.convert(binop(op_name, const(5), const(3)), Context.new())
        assert ast == {helper, [], [5, 3]}
      end
    end

    test "MatMult raises explicitly with a dedicated hint" do
      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(binop("MatMult", const(1), const(2)), Context.new())
        end

      assert err.node_type == "MatMult"
      assert err.hint =~ "matrix"
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

  describe "end-to-end — T11 ops" do
    test "FloorDiv: -7 // 2 == -4 (Python floor, not truncate)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("FloorDiv", const(-7), const(2))))

      assert value == -4
    end

    test "Mod: -7 % 2 == 1 (Python floor-modulo, sign follows divisor)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("Mod", const(-7), const(2))))

      assert value == 1
    end

    test "LShift: 1 << 4 == 16" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("LShift", const(1), const(4))))

      assert value == 16
    end

    test "BitXor: 5 ^ 3 == 6" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(binop("BitXor", const(5), const(3))))

      assert value == 6
    end

    test "Mod with string left operand applies Python %-formatting" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(binop("Mod", const("hello %s"), const("world")))
        )

      assert value == "hello world"
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
