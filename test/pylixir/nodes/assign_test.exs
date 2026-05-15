defmodule Pylixir.Nodes.AssignTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp op(name), do: %{"_type" => name}

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

  describe "single Name target" do
    test "x = 5 emits {:=, [], [x, 5]}" do
      {ast, ctx} = Converter.convert(assign([name("x")], const(5)), Context.new())
      assert ast == {:=, [], [{:x, [], nil}, 5]}
      assert MapSet.member?(hd(ctx.scopes), "x")
    end

    test "x = y references y as a Name" do
      {ast, _} = Converter.convert(assign([name("x")], name("y")), Context.new())
      assert ast == {:=, [], [{:x, [], nil}, {:y, [], nil}]}
    end

    test "reserved-name target rewrites to var_<id>" do
      {ast, _} = Converter.convert(assign([name("if")], const(1)), Context.new())
      assert ast == {:=, [], [{:var_if, [], nil}, 1]}
    end
  end

  describe "Tuple target" do
    test "{a, b} = {1, 2} 2-tuple" do
      tup_target = %{"_type" => "Tuple", "elts" => [name("a"), name("b")]}
      tup_value = %{"_type" => "Tuple", "elts" => [const(1), const(2)]}
      {ast, ctx} = Converter.convert(assign([tup_target], tup_value), Context.new())

      assert ast == {:=, [], [{{:a, [], nil}, {:b, [], nil}}, {1, 2}]}
      assert MapSet.member?(hd(ctx.scopes), "a")
      assert MapSet.member?(hd(ctx.scopes), "b")
    end

    test "n=3 tuple uses {:{}, [], elts} on both sides" do
      tup_target = %{"_type" => "Tuple", "elts" => [name("a"), name("b"), name("c")]}
      tup_value = %{"_type" => "Tuple", "elts" => [const(1), const(2), const(3)]}
      {ast, _} = Converter.convert(assign([tup_target], tup_value), Context.new())

      assert ast ==
               {:=, [],
                [
                  {:{}, [], [{:a, [], nil}, {:b, [], nil}, {:c, [], nil}]},
                  {:{}, [], [1, 2, 3]}
                ]}
    end

    test "Starred in tuple target raises" do
      starred = %{"_type" => "Starred", "value" => name("rest")}
      tup_target = %{"_type" => "Tuple", "elts" => [name("a"), starred]}
      tup_value = %{"_type" => "Tuple", "elts" => [const(1), const(2)]}

      assert_raise UnsupportedNodeError, ~r/star-unpack/, fn ->
        Converter.convert(assign([tup_target], tup_value), Context.new())
      end
    end

    test "non-Name element in tuple target raises" do
      tup_target = %{"_type" => "Tuple", "elts" => [name("a"), const(5)]}
      tup_value = %{"_type" => "Tuple", "elts" => [const(1), const(2)]}

      assert_raise UnsupportedNodeError, ~r/Name/, fn ->
        Converter.convert(assign([tup_target], tup_value), Context.new())
      end
    end
  end

  describe "Subscript target (plain Assign)" do
    test "lst[0] = 5 rewrites to lst = py_setitem(lst, 0, 5)" do
      target = %{"_type" => "Subscript", "value" => name("lst"), "slice" => const(0)}
      {ast, ctx} = Converter.convert(assign([target], const(5)), Context.new())

      assert ast ==
               {:=, [],
                [
                  {:lst, [], nil},
                  {:py_setitem, [], [{:lst, [], nil}, 0, 5]}
                ]}

      assert MapSet.member?(hd(ctx.scopes), "lst")
    end

    test "non-Name-rooted subscript target raises (T14 territory)" do
      # A Subscript whose collection is itself a Subscript: nested.
      inner = %{"_type" => "Subscript", "value" => name("matrix"), "slice" => const(0)}
      target = %{"_type" => "Subscript", "value" => inner, "slice" => const(0)}

      assert_raise UnsupportedNodeError, ~r/Subscript/, fn ->
        Converter.convert(assign([target], const(5)), Context.new())
      end
    end
  end

  describe "Multi-target (a = b = ...)" do
    test "trivial RHS — inline both Assigns" do
      {ast, ctx} =
        Converter.convert(
          assign([name("a"), name("b")], const(5)),
          Context.new()
        )

      assert ast ==
               {:__block__, [],
                [
                  {:=, [], [{:a, [], nil}, 5]},
                  {:=, [], [{:b, [], nil}, 5]}
                ]}

      assert MapSet.member?(hd(ctx.scopes), "a")
      assert MapSet.member?(hd(ctx.scopes), "b")
    end

    test "non-trivial RHS — bind to py_tmp_0 first, then assign each target from the temp" do
      {ast, ctx} =
        Converter.convert(
          assign([name("a"), name("b")], non_trivial(5)),
          Context.new()
        )

      {:__block__, [], stmts} = ast
      assert length(stmts) == 3
      [binding, a_assign, b_assign] = stmts

      assert match?({:=, [], [{:py_tmp_0, [], nil}, _]}, binding)
      assert a_assign == {:=, [], [{:a, [], nil}, {:py_tmp_0, [], nil}]}
      assert b_assign == {:=, [], [{:b, [], nil}, {:py_tmp_0, [], nil}]}

      assert ctx.temp_counter == 1
    end

    test "non-Name target in multi-Assign raises" do
      target_2 = %{"_type" => "Tuple", "elts" => [name("x"), name("y")]}

      assert_raise UnsupportedNodeError, ~r/multi-target/, fn ->
        Converter.convert(assign([name("a"), target_2], const(5)), Context.new())
      end
    end
  end

  describe "end-to-end via transpile_and_run" do
    test "x = 5 then x as the final statement" do
      ast =
        module_with([
          assign([name("x")], const(5)),
          name("x")
        ])

      {_, value, _, diagnostics} = TranspileHelpers.transpile_and_run(ast)
      assert value == 5
      assert diagnostics == []
    end

    test "tuple swap: a, b = b, a" do
      ast =
        module_with([
          assign([name("a")], const(1)),
          assign([name("b")], const(2)),
          assign(
            [%{"_type" => "Tuple", "elts" => [name("a"), name("b")]}],
            %{"_type" => "Tuple", "elts" => [name("b"), name("a")]}
          ),
          %{"_type" => "Tuple", "elts" => [name("a"), name("b")]}
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == {2, 1}
    end

    test "subscript-target Assign mutates the list" do
      lst = %{"_type" => "List", "elts" => [const(10), const(20), const(30)]}

      ast =
        module_with([
          assign([name("xs")], lst),
          assign(
            [%{"_type" => "Subscript", "value" => name("xs"), "slice" => const(1)}],
            const(99)
          ),
          name("xs")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == [10, 99, 30]
    end
  end
end
