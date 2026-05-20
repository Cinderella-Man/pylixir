defmodule Pylixir.Nodes.BoolOpTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp op(name), do: %{"_type" => name}

  defp bool_op(op_name, values),
    do: %{"_type" => "BoolOp", "op" => op(op_name), "values" => values}

  defp module_with(stmt), do: %{"_type" => "Module", "body" => [stmt]}

  describe "AST shape — all operands statically bool → fast Elixir &&/||" do
    test "true and false → single &&" do
      {ast, _} =
        Converter.convert(bool_op("And", [const(true), const(false)]), Context.new())

      assert ast == {:&&, [], [true, false]}
    end

    test "true or false → single ||" do
      {ast, _} = Converter.convert(bool_op("Or", [const(true), const(false)]), Context.new())
      assert ast == {:||, [], [true, false]}
    end

    test "true and true and false → left-fold of &&" do
      {ast, _} =
        Converter.convert(
          bool_op("And", [const(true), const(true), const(false)]),
          Context.new()
        )

      assert ast == {:&&, [], [{:&&, [], [true, true]}, false]}
    end
  end

  describe "AST shape — non-bool operand falls back to case + truthy?" do
    # Ints and other non-bool literals can't use Elixir's `&&` directly
    # because `0`, `""`, `[]` etc. are Python-falsy but Elixir-truthy.
    # Emit a `case` that mirrors Python's value-returning short-circuit.
    test "1 and 2 → case form (LHS is int, not bool)" do
      {ast, _} = Converter.convert(bool_op("And", [const(1), const(2)]), Context.new())

      assert match?(
               {:case, [],
                [
                  1,
                  [
                    do: [
                      {:->, [],
                       [
                         [{:py_bool_v, [], nil}],
                         {:if, [],
                          [
                            {:truthy?, [], [{:py_bool_v, [], nil}]},
                            [do: 2, else: {:py_bool_v, [], nil}]
                          ]}
                       ]}
                    ]
                  ]
                ]},
               ast
             )
    end

    test "1 or 2 → case form with branches flipped" do
      {ast, _} = Converter.convert(bool_op("Or", [const(1), const(2)]), Context.new())

      assert match?(
               {:case, [],
                [
                  1,
                  [
                    do: [
                      {:->, [],
                       [
                         [{:py_bool_v, [], nil}],
                         {:if, [],
                          [
                            {:truthy?, [], [{:py_bool_v, [], nil}]},
                            [do: {:py_bool_v, [], nil}, else: 2]
                          ]}
                       ]}
                    ]
                  ]
                ]},
               ast
             )
    end
  end

  describe "end-to-end — RFC §6.3 cases where Elixir && / || semantics agree with Python and/or" do
    test "And of two truthy values returns the last (1 and 2 == 2)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(module_with(bool_op("And", [const(1), const(2)])))

      assert value == 2
    end

    test "And short-circuits on nil/None" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(bool_op("And", [const(nil), const("never")]))
        )

      assert value == nil
    end

    test "Or short-circuits on nil/None (False or X → X when False maps to nil/false)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(bool_op("Or", [const(false), const("found")]))
        )

      assert value == "found"
    end

    # `0 and X` and `"" or X` used to be documented divergences (RFC
    # §6.3) — Elixir's truthiness treats 0 and "" as truthy. The eval
    # corpus surfaced this as a real bug (`while queue and cond:` with
    # `queue == []` entered the loop body and crashed on `popleft`), so
    # we now fall back to Python's value-returning short-circuit when
    # operand types aren't statically `{:bool}`.
    test "[] and X returns [] (Python falsy, Elixir truthy)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(bool_op("And", [%{"_type" => "List", "elts" => []}, const("never")]))
        )

      assert value == []
    end

    test "0 and X returns 0 (Python falsy)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(bool_op("And", [const(0), const("never")]))
        )

      assert value == 0
    end

    test "\"\" or X returns X (Python: empty string is falsy)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(bool_op("Or", [const(""), const("fallback")]))
        )

      assert value == "fallback"
    end

    test "[] or [1, 2] returns [1, 2] (Python: empty list is falsy)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(
            bool_op("Or", [
              %{"_type" => "List", "elts" => []},
              %{"_type" => "List", "elts" => [const(1), const(2)]}
            ])
          )
        )

      assert value == [1, 2]
    end

    test "[1] and \"hi\" returns \"hi\" (LHS truthy → returns RHS)" do
      {_, value, _, _} =
        TranspileHelpers.transpile_and_run(
          module_with(
            bool_op("And", [%{"_type" => "List", "elts" => [const(1)]}, const("hi")])
          )
        )

      assert value == "hi"
    end
  end
end
