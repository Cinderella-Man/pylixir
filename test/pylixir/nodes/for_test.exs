defmodule Pylixir.Nodes.ForTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp op(n), do: %{"_type" => n}
  defp list_node(elts), do: %{"_type" => "List", "elts" => elts}

  defp assign(target, value),
    do: %{"_type" => "Assign", "targets" => [target], "value" => value}

  defp aug_assign(target, op_name, value),
    do: %{"_type" => "AugAssign", "target" => target, "op" => op(op_name), "value" => value}

  defp for_node(target, iter, body, orelse \\ []),
    do: %{
      "_type" => "For",
      "target" => target,
      "iter" => iter,
      "body" => body,
      "orelse" => orelse
    }

  defp module_with(stmts), do: %{"_type" => "Module", "body" => stmts}

  describe "For.orelse handling" do
    test "non-empty orelse lowers to an else-block guarded by `unless broke?`" do
      # for i in []: pass else: 42 — empty iter, no break, else runs.
      {ast, _} =
        Converter.convert(
          for_node(name("i"), list_node([]), [%{"_type" => "Pass"}], [const(42)]),
          Context.new()
        )

      rendered = Macro.to_string(ast)
      # The for/else emission wraps the loop in a try producing
      # {state, broke?} and dispatches to the else-block via !broke?.
      assert rendered =~ "pylixir_broke?"
      assert rendered =~ "42"
    end
  end

  describe "no assigned vars → Enum.each" do
    test "pure side-effect loop emits Enum.each, not Enum.reduce" do
      # for i in [1, 2]: pass
      {ast, _} =
        Converter.convert(
          for_node(name("i"), list_node([const(1), const(2)]), [%{"_type" => "Pass"}]),
          Context.new()
        )

      assert match?({{:., [], [{:__aliases__, [], [:Enum]}, :each]}, [], _}, ast)
    end
  end

  describe "single assigned var → Enum.reduce with bare acc" do
    test "summation: total = total + i, threaded through reduce" do
      body = [aug_assign(name("total"), "Add", name("i"))]

      {ast, _} =
        Converter.convert(
          for_node(name("i"), list_node([const(1), const(2), const(3)]), body),
          Context.new()
        )

      # The whole For becomes `total = Enum.reduce(...)`.
      assert match?({:=, [], [{:total, [], nil}, _reduce_call]}, ast)
      {:=, [], [_, reduce_call]} = ast

      assert match?({{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], _}, reduce_call)
    end

    test "initial acc is nil when the var isn't bound outside" do
      body = [aug_assign(name("total"), "Add", name("i"))]
      {ast, _} = Converter.convert(for_node(name("i"), list_node([]), body), Context.new())

      {:=, [], [_, {_, [], [_iter, initial, _fn]}]} = ast
      assert initial == nil
    end
  end

  describe "multiple assigned vars → Enum.reduce with tuple acc" do
    test "{total, count} = Enum.reduce(...)" do
      body = [
        aug_assign(name("total"), "Add", name("i")),
        aug_assign(name("count"), "Add", const(1))
      ]

      {ast, _} = Converter.convert(for_node(name("i"), list_node([]), body), Context.new())

      # {count, total} = Enum.reduce(...). (alphabetical from MapSet sort)
      assert match?({:=, [], [{_, _}, _reduce_call]}, ast)
    end
  end

  describe "loop var exclusion from accumulator" do
    test "loop var rebinding inside body does NOT thread through the accumulator" do
      # for i in xs: i = 99 — the rebinding stays inside the fn.
      body = [assign(name("i"), const(99))]
      {ast, _} = Converter.convert(for_node(name("i"), list_node([]), body), Context.new())

      # Because the only assigned var is `i` (= loop var), it's excluded and
      # we fall to the Enum.each branch.
      assert match?({{:., [], [{:__aliases__, [], [:Enum]}, :each]}, [], _}, ast)
    end
  end

  describe "end-to-end" do
    test "summation: total = 0; for i in [1,2,3,4,5]: total += i → 15" do
      ast =
        module_with([
          assign(name("total"), const(0)),
          for_node(
            name("i"),
            list_node([const(1), const(2), const(3), const(4), const(5)]),
            [aug_assign(name("total"), "Add", name("i"))]
          ),
          name("total")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 15
    end

    test "two-variable threading: total and count" do
      ast =
        module_with([
          assign(name("total"), const(0)),
          assign(name("count"), const(0)),
          for_node(
            name("i"),
            list_node([const(10), const(20), const(30)]),
            [
              aug_assign(name("total"), "Add", name("i")),
              aug_assign(name("count"), "Add", const(1))
            ]
          ),
          %{"_type" => "Tuple", "elts" => [name("total"), name("count")]}
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == {60, 3}
    end

    test "tuple-unpack loop target: for (a, b) in pairs" do
      pairs =
        list_node([
          %{"_type" => "Tuple", "elts" => [const(1), const(10)]},
          %{"_type" => "Tuple", "elts" => [const(2), const(20)]}
        ])

      ast =
        module_with([
          assign(name("sum"), const(0)),
          for_node(
            %{"_type" => "Tuple", "elts" => [name("a"), name("b")]},
            pairs,
            [
              aug_assign(name("sum"), "Add", aug_target = name("a")),
              aug_assign(name("sum"), "Add", aug_target_2 = name("b"))
            ]
          ),
          name("sum")
        ])

      _ = {aug_target, aug_target_2}
      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      # 1 + 10 + 2 + 20 = 33
      assert value == 33
    end

    test "Python-falsy 0 in list — loop iterates over all elements" do
      ast =
        module_with([
          assign(name("count"), const(0)),
          for_node(
            name("x"),
            list_node([const(0), const(0), const(0)]),
            [aug_assign(name("count"), "Add", const(1))]
          ),
          name("count")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 3
    end
  end
end
