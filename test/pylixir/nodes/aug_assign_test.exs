defmodule Pylixir.Nodes.AugAssignTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp op(name), do: %{"_type" => name}

  defp aug_assign(target, op_name, value),
    do: %{"_type" => "AugAssign", "target" => target, "op" => op(op_name), "value" => value}

  defp assign(targets, value),
    do: %{"_type" => "Assign", "targets" => targets, "value" => value}

  defp non_trivial(value),
    do: %{
      "_type" => "BinOp",
      "op" => op("Add"),
      "left" => const(value),
      "right" => const(0)
    }

  defp module_with(stmts) when is_list(stmts),
    do: %{"_type" => "Module", "body" => stmts}

  describe "AST shape — Name target, each op" do
    test "x += 1 rewrites to x = py_add(x, 1)" do
      {ast, _} = Converter.convert(aug_assign(name("x"), "Add", const(1)), Context.new())
      assert ast == {:=, [], [{:x, [], nil}, {:py_add, [], [{:x, [], nil}, 1]}]}
    end

    test "x -= 1 routes through py_sub (handles bool coercion per RFC §6.11)" do
      {ast, _} = Converter.convert(aug_assign(name("x"), "Sub", const(1)), Context.new())
      assert ast == {:=, [], [{:x, [], nil}, {:py_sub, [], [{:x, [], nil}, 1]}]}
    end

    test "x *= 2 rewrites via py_mult" do
      {ast, _} = Converter.convert(aug_assign(name("x"), "Mult", const(2)), Context.new())
      assert ast == {:=, [], [{:x, [], nil}, {:py_mult, [], [{:x, [], nil}, 2]}]}
    end

    test "x //= 2 rewrites via py_floor_div (T11)" do
      {ast, _} = Converter.convert(aug_assign(name("x"), "FloorDiv", const(2)), Context.new())
      assert ast == {:=, [], [{:x, [], nil}, {:py_floor_div, [], [{:x, [], nil}, 2]}]}
    end

    test "bitwise/set-overload AugAssign routes through py_bxor helper" do
      # Python's `^=` overloads set symmetric-difference on top of
      # int XOR. The helper dispatches on operand type.
      {ast, _} = Converter.convert(aug_assign(name("x"), "BitXor", const(3)), Context.new())

      assert ast == {:=, [], [{:x, [], nil}, {:py_bxor, [], [{:x, [], nil}, 3]}]}
    end
  end

  describe "AST shape — Subscript target" do
    test "d[k] += 1 with trivial collection + slice — no temp, single __block__-free rewrite" do
      target = %{"_type" => "Subscript", "value" => name("d"), "slice" => name("k")}
      {ast, _ctx} = Converter.convert(aug_assign(target, "Add", const(1)), Context.new())

      assert ast ==
               {:=, [],
                [
                  {:d, [], nil},
                  {:py_setitem, [],
                   [
                     {:d, [], nil},
                     {:k, [], nil},
                     {:py_add, [], [{:py_getitem, [], [{:d, [], nil}, {:k, [], nil}]}, 1]}
                   ]}
                ]}
    end

    test "non-trivial slice binds a py_tmp first (single-eval)" do
      target = %{"_type" => "Subscript", "value" => name("d"), "slice" => non_trivial(7)}
      {ast, ctx} = Converter.convert(aug_assign(target, "Add", const(1)), Context.new())

      assert match?({:__block__, [], [_slice_binding, _assign]}, ast)
      {:__block__, [], [slice_binding, _assign]} = ast
      assert match?({:=, [], [{:py_tmp_0, [], nil}, _]}, slice_binding)
      assert ctx.temp_counter == 1
    end

    test "non-trivial collection AND slice produce two temps" do
      coll = non_trivial(99)
      slice = non_trivial(7)
      target = %{"_type" => "Subscript", "value" => coll, "slice" => slice}
      {ast, ctx} = Converter.convert(aug_assign(target, "Add", const(1)), Context.new())

      assert match?({:__block__, [], [_, _, _setitem_only]}, ast)
      {:__block__, [], [_b1, _b2, _]} = ast
      assert ctx.temp_counter == 2
    end
  end

  describe "AST shape — unsupported targets" do
    test "Attribute target raises" do
      target = %{"_type" => "Attribute", "value" => name("obj"), "attr" => "x"}

      assert_raise UnsupportedNodeError, ~r/AugAssign/, fn ->
        Converter.convert(aug_assign(target, "Add", const(1)), Context.new())
      end
    end
  end

  describe "end-to-end" do
    test "x = 1; x += 1; x == 2" do
      ast =
        module_with([
          assign([name("x")], const(1)),
          aug_assign(name("x"), "Add", const(1)),
          name("x")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 2
    end

    test "d = %{}; d[k] = 0; d[k] += 5 — final dict is %{k => 5}" do
      empty_dict = %{"_type" => "Dict", "keys" => [], "values" => []}

      ast =
        module_with([
          assign([name("d")], empty_dict),
          assign([name("k")], const("foo")),
          assign(
            [%{"_type" => "Subscript", "value" => name("d"), "slice" => name("k")}],
            const(0)
          ),
          aug_assign(
            %{"_type" => "Subscript", "value" => name("d"), "slice" => name("k")},
            "Add",
            const(5)
          ),
          name("d")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == %{"foo" => 5}
    end

    test "list element AugAssign via Mult" do
      lst = %{"_type" => "List", "elts" => [const(2), const(3), const(4)]}

      ast =
        module_with([
          assign([name("xs")], lst),
          aug_assign(
            %{"_type" => "Subscript", "value" => name("xs"), "slice" => const(1)},
            "Mult",
            const(10)
          ),
          name("xs")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == [2, 30, 4]
    end
  end
end
