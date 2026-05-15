defmodule Pylixir.Nodes.WhileTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Converter, TranspileHelpers, UnsupportedNodeError}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp op(n), do: %{"_type" => n}

  defp assign(target, value),
    do: %{"_type" => "Assign", "targets" => [target], "value" => value}

  defp aug_assign(target, op_name, value),
    do: %{"_type" => "AugAssign", "target" => target, "op" => op(op_name), "value" => value}

  defp compare(left, op_name, right),
    do: %{"_type" => "Compare", "left" => left, "ops" => [op(op_name)], "comparators" => [right]}

  defp if_node(test, body),
    do: %{"_type" => "If", "test" => test, "body" => body, "orelse" => []}

  defp while_node(test, body, orelse \\ []),
    do: %{"_type" => "While", "test" => test, "body" => body, "orelse" => orelse}

  defp module_with(stmts), do: %{"_type" => "Module", "body" => stmts}

  describe "While.orelse rejection" do
    test "non-empty orelse raises" do
      assert_raise UnsupportedNodeError, ~r/while\/else/, fn ->
        Converter.convert(
          while_node(const(true), [%{"_type" => "Pass"}], [const(1)]),
          Pylixir.Context.new()
        )
      end
    end
  end

  describe "end-to-end" do
    test "counts up: while i < 5: i += 1 → 5" do
      ast =
        module_with([
          assign(name("i"), const(0)),
          while_node(compare(name("i"), "Lt", const(5)), [
            aug_assign(name("i"), "Add", const(1))
          ]),
          name("i")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 5
    end

    test "summation: i = 0; total = 0; while i < 5: total += i; i += 1 → 10" do
      ast =
        module_with([
          assign(name("i"), const(0)),
          assign(name("total"), const(0)),
          while_node(compare(name("i"), "Lt", const(5)), [
            aug_assign(name("total"), "Add", name("i")),
            aug_assign(name("i"), "Add", const(1))
          ]),
          name("total")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 10
    end

    test "break exits the while loop with current state" do
      ast =
        module_with([
          assign(name("i"), const(0)),
          while_node(compare(name("i"), "Lt", const(100)), [
            if_node(compare(name("i"), "GtE", const(7)), [%{"_type" => "Break"}]),
            aug_assign(name("i"), "Add", const(1))
          ]),
          name("i")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 7
    end

    test "continue skips iteration but still advances loop var (with i++ before continue)" do
      # i = 0; total = 0
      # while i < 5:
      #     i += 1
      #     if i == 3: continue
      #     total += i
      # total == 1+2+4+5 = 12
      ast =
        module_with([
          assign(name("i"), const(0)),
          assign(name("total"), const(0)),
          while_node(compare(name("i"), "Lt", const(5)), [
            aug_assign(name("i"), "Add", const(1)),
            if_node(compare(name("i"), "Eq", const(3)), [%{"_type" => "Continue"}]),
            aug_assign(name("total"), "Add", name("i"))
          ]),
          name("total")
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 12
    end
  end
end
