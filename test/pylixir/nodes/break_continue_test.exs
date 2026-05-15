defmodule Pylixir.Nodes.BreakContinueTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp op(n), do: %{"_type" => n}
  defp list_node(elts), do: %{"_type" => "List", "elts" => elts}

  defp assign(target, value),
    do: %{"_type" => "Assign", "targets" => [target], "value" => value}

  defp aug_assign(target, op_name, value),
    do: %{"_type" => "AugAssign", "target" => target, "op" => op(op_name), "value" => value}

  defp compare(left, op_name, right),
    do: %{"_type" => "Compare", "left" => left, "ops" => [op(op_name)], "comparators" => [right]}

  defp if_node(test, body),
    do: %{"_type" => "If", "test" => test, "body" => body, "orelse" => []}

  defp for_node(target, iter, body),
    do: %{"_type" => "For", "target" => target, "iter" => iter, "body" => body, "orelse" => []}

  defp module_with(stmts), do: %{"_type" => "Module", "body" => stmts}

  describe "Break/Continue outside a loop raise" do
    test "Break outside any loop" do
      assert_raise UnsupportedNodeError, ~r/Break/, fn ->
        Converter.convert(%{"_type" => "Break"}, Context.new())
      end
    end

    test "Continue outside any loop" do
      assert_raise UnsupportedNodeError, ~r/Continue/, fn ->
        Converter.convert(%{"_type" => "Continue"}, Context.new())
      end
    end
  end

  describe "end-to-end — break in a single-acc reduce" do
    test "early break returns the accumulator value at break time" do
      # total = 0; for i in [1,2,3,4,5]: if i > 3: break; total += i → 6
      ast =
        module_with([
          assign(name("total"), const(0)),
          for_node(
            name("i"),
            list_node([const(1), const(2), const(3), const(4), const(5)]),
            [
              if_node(compare(name("i"), "Gt", const(3)), [%{"_type" => "Break"}]),
              aug_assign(name("total"), "Add", name("i"))
            ]
          ),
          name("total")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 6
    end
  end

  describe "end-to-end — continue in a single-acc reduce" do
    test "continue skips the rest of the iteration" do
      # total = 0; for i in [1,2,3,4,5]: if i == 3: continue; total += i → 12
      ast =
        module_with([
          assign(name("total"), const(0)),
          for_node(
            name("i"),
            list_node([const(1), const(2), const(3), const(4), const(5)]),
            [
              if_node(compare(name("i"), "Eq", const(3)), [%{"_type" => "Continue"}]),
              aug_assign(name("total"), "Add", name("i"))
            ]
          ),
          name("total")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 12
    end
  end

  describe "end-to-end — break in a tuple-acc reduce" do
    test "break preserves both accumulator vars" do
      # total = 0; count = 0
      # for i in [1,2,3,4,5]:
      #   if i > 2: break
      #   total += i
      #   count += 1
      # (total, count) → (3, 2)
      ast =
        module_with([
          assign(name("total"), const(0)),
          assign(name("count"), const(0)),
          for_node(
            name("i"),
            list_node([const(1), const(2), const(3), const(4), const(5)]),
            [
              if_node(compare(name("i"), "Gt", const(2)), [%{"_type" => "Break"}]),
              aug_assign(name("total"), "Add", name("i")),
              aug_assign(name("count"), "Add", const(1))
            ]
          ),
          %{"_type" => "Tuple", "elts" => [name("total"), name("count")]}
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == {3, 2}
    end
  end

  describe "end-to-end — Enum.each with break (pure side-effect loop)" do
    test "break terminates the each early; loop body had no assigns" do
      # for i in [1,2,3]: if i == 2: break  (just runs, returns :ok)
      ast =
        module_with([
          for_node(
            name("i"),
            list_node([const(1), const(2), const(3)]),
            [
              if_node(compare(name("i"), "Eq", const(2)), [%{"_type" => "Break"}])
            ]
          )
        ])

      # No threaded accumulator, but the loop is still side-effect-only.
      # transpile_and_run completes without raising.
      {_, _, _, diagnostics} = TranspileHelpers.transpile_and_run(ast)
      assert diagnostics == []
    end
  end

  describe "nested loops: inner break/continue belong to inner only" do
    test "inner-loop break does not terminate the outer loop" do
      # total = 0
      # for i in [1, 2, 3]:
      #   for j in [10, 20, 30]:
      #     if j == 20: break
      #     total += j
      # total → 10 + 10 + 10 (j=10 added each outer iteration before break) = 30
      ast =
        module_with([
          assign(name("total"), const(0)),
          for_node(
            name("i"),
            list_node([const(1), const(2), const(3)]),
            [
              for_node(
                name("j"),
                list_node([const(10), const(20), const(30)]),
                [
                  if_node(compare(name("j"), "Eq", const(20)), [%{"_type" => "Break"}]),
                  aug_assign(name("total"), "Add", name("j"))
                ]
              )
            ]
          ),
          name("total")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 30
    end
  end
end
