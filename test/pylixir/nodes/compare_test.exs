defmodule Pylixir.Nodes.CompareTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp op(name), do: %{"_type" => name}

  # T10 BinOp serves as a stand-in for a non-trivial expression
  # until T28's Call routing lands.
  defp non_trivial(value),
    do: %{
      "_type" => "BinOp",
      "op" => op("Add"),
      "left" => const(value),
      "right" => const(0)
    }

  defp compare(left, ops, comparators),
    do: %{
      "_type" => "Compare",
      "left" => left,
      "ops" => Enum.map(ops, &op/1),
      "comparators" => comparators
    }

  defp module_with(stmt), do: %{"_type" => "Module", "body" => [stmt]}

  describe "AST shape — single-comparator Compares emit a plain binary op" do
    test "1 < 2 → {:<, [], [1, 2]}" do
      {ast, _} = Converter.convert(compare(const(1), ["Lt"], [const(2)]), Context.new())
      assert ast == {:<, [], [1, 2]}
    end

    test "x == y" do
      {ast, _} =
        Converter.convert(compare(name("x"), ["Eq"], [name("y")]), Context.new())

      assert ast == {:==, [], [{:x, [], nil}, {:y, [], nil}]}
    end

    test "Is/IsNot map to ==/!= per RFC §10.10" do
      {is_ast, _} = Converter.convert(compare(name("x"), ["Is"], [const(nil)]), Context.new())
      {isnot_ast, _} =
        Converter.convert(compare(name("x"), ["IsNot"], [const(nil)]), Context.new())

      assert is_ast == {:==, [], [{:x, [], nil}, nil]}
      assert isnot_ast == {:!=, [], [{:x, [], nil}, nil]}
    end

    test "In/NotIn route through py_in" do
      lst = %{"_type" => "List", "elts" => [const(1), const(2)]}
      {in_ast, _} = Converter.convert(compare(name("x"), ["In"], [lst]), Context.new())
      {notin_ast, _} = Converter.convert(compare(name("x"), ["NotIn"], [lst]), Context.new())

      assert in_ast == {:py_in, [], [{:x, [], nil}, [1, 2]]}
      assert notin_ast == {:!, [], [{:py_in, [], [{:x, [], nil}, [1, 2]]}]}
    end
  end

  describe "AST shape — chained Compare with trivial middles (no temp)" do
    test "1 < x < 10 — `x` is a Name (trivial), no __block__/temps" do
      {ast, _} =
        Converter.convert(
          compare(const(1), ["Lt", "Lt"], [name("x"), const(10)]),
          Context.new()
        )

      # Should be a flat &&-chain with x referenced twice, no temp binding.
      assert ast ==
               {:&&, [],
                [
                  {:<, [], [1, {:x, [], nil}]},
                  {:<, [], [{:x, [], nil}, 10]}
                ]}
    end

    test "Constant middles also stay inline (constants are trivial)" do
      {ast, _} =
        Converter.convert(
          compare(name("a"), ["Lt", "Lt"], [const(5), name("b")]),
          Context.new()
        )

      refute match?({:__block__, _, _}, ast)
    end
  end

  describe "AST shape — chained Compare with non-trivial middles (temp binding)" do
    test "1 < (5 + 0) < 10 wraps in __block__ with a py_tmp_0 binding" do
      {ast, ctx} =
        Converter.convert(
          compare(const(1), ["Lt", "Lt"], [non_trivial(5), const(10)]),
          Context.new()
        )

      assert match?({:__block__, [], [_binding, _chain]}, ast)
      {:__block__, [], [binding, chain]} = ast

      # The temp binding: py_tmp_0 = py_add(5, 0)
      assert match?({:=, [], [{:py_tmp_0, [], nil}, _add_ast]}, binding)

      # The chain references py_tmp_0 on both sides.
      assert chain ==
               {:&&, [],
                [
                  {:<, [], [1, {:py_tmp_0, [], nil}]},
                  {:<, [], [{:py_tmp_0, [], nil}, 10]}
                ]}

      assert ctx.temp_counter == 1
    end

    test "two non-trivial middles get distinct temps (counter increments)" do
      {ast, ctx} =
        Converter.convert(
          compare(
            const(0),
            ["Lt", "Lt", "Lt"],
            [non_trivial(5), non_trivial(10), const(99)]
          ),
          Context.new()
        )

      assert ctx.temp_counter == 2
      {:__block__, [], stmts} = ast
      assert length(stmts) == 3
      [binding_a, binding_b, _chain] = stmts

      assert match?({:=, [], [{:py_tmp_0, [], nil}, _]}, binding_a)
      assert match?({:=, [], [{:py_tmp_1, [], nil}, _]}, binding_b)
    end

    test "the LAST comparator is never tempted (only used once)" do
      {ast, _} =
        Converter.convert(
          compare(const(1), ["Lt", "Lt"], [name("x"), non_trivial(20)]),
          Context.new()
        )

      # `x` is trivial (Name), so no temp for the middle either.
      # The last comparator is used only once → never bound, even if
      # non-trivial.
      refute match?({:__block__, _, _}, ast)
    end
  end

  describe "end-to-end" do
    test "1 < 5 < 10 evaluates to true" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(compare(const(1), ["Lt", "Lt"], [const(5), const(10)]))
        )

      assert value == true
    end

    test "1 < 0 < 10 short-circuits to false" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(compare(const(1), ["Lt", "Lt"], [const(0), const(10)]))
        )

      assert value == false
    end

    test "x in [1,2,3] when x is 2" do
      lst = %{"_type" => "List", "elts" => [const(1), const(2), const(3)]}

      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(compare(const(2), ["In"], [lst]))
        )

      assert value == true
    end

    test "5 not in [1,2,3]" do
      lst = %{"_type" => "List", "elts" => [const(1), const(2), const(3)]}

      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(compare(const(5), ["NotIn"], [lst]))
        )

      assert value == true
    end

    test "x is None when x is nil" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(compare(const(nil), ["Is"], [const(nil)]))
        )

      assert value == true
    end
  end
end
