defmodule Pylixir.Nodes.IfTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, TranspileHelpers}

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp op(n), do: %{"_type" => n}

  defp compare(left, op_name, right),
    do: %{"_type" => "Compare", "left" => left, "ops" => [op(op_name)], "comparators" => [right]}

  defp if_node(test, body, orelse \\ []),
    do: %{"_type" => "If", "test" => test, "body" => body, "orelse" => orelse}

  defp assign(targets, value),
    do: %{"_type" => "Assign", "targets" => targets, "value" => value}

  defp module_with(stmts), do: %{"_type" => "Module", "body" => stmts}

  describe "Pass" do
    test "emits the :ok atom" do
      {ast, _} = Converter.convert(%{"_type" => "Pass"}, Context.new())
      assert ast == :ok
    end
  end

  describe "If — three shapes" do
    test "orelse=[] → bare `if cond, do: body`" do
      {ast, _} =
        Converter.convert(
          if_node(compare(name("x"), "Gt", const(0)), [const(1)]),
          Context.new()
        )

      # Compare test → no truthy? wrap; body single stmt → no __block__.
      # `x` is untyped (:any), so `>` lowers to the nil-coercing `py_gt`.
      assert ast == {:if, [], [{:py_gt, [], [{:x, [], nil}, 0]}, [do: 1]]}
    end

    test "orelse is a non-If statement → `if cond, do: body, else: orelse`" do
      {ast, _} =
        Converter.convert(
          if_node(compare(name("x"), "Gt", const(0)), [const(1)], [const(2)]),
          Context.new()
        )

      assert ast ==
               {:if, [],
                [
                  {:py_gt, [], [{:x, [], nil}, 0]},
                  [do: 1, else: 2]
                ]}
    end

    test "orelse is [If(...)] (elif chain) → cond with mandatory `true -> nil`" do
      elif_chain =
        if_node(
          compare(name("x"), "Gt", const(0)),
          [const(1)],
          [
            if_node(
              compare(name("x"), "Lt", const(0)),
              [const(-1)]
            )
          ]
        )

      {ast, _} = Converter.convert(elif_chain, Context.new())

      assert match?({:cond, [], [[do: _]]}, ast)
      {:cond, [], [[do: clauses]]} = ast

      # 2 elif arms + 1 fallthrough `true -> nil`
      assert length(clauses) == 3
      last_clause = List.last(clauses)
      assert match?({:->, [], [[true], nil]}, last_clause)
    end

    test "elif chain WITH a terminal else uses the else body in the `true ->` arm" do
      elif_with_else =
        if_node(
          compare(name("x"), "Gt", const(0)),
          [const(1)],
          [
            if_node(
              compare(name("x"), "Lt", const(0)),
              [const(-1)],
              [const(0)]
            )
          ]
        )

      {ast, _} = Converter.convert(elif_with_else, Context.new())
      {:cond, [], [[do: clauses]]} = ast

      last_clause = List.last(clauses)
      assert last_clause == {:->, [], [[true], 0]}
    end
  end

  describe "If — truthy? wrap policy" do
    test "non-Compare test gets the truthy? wrap" do
      {ast, _} = Converter.convert(if_node(name("x"), [const(1)]), Context.new())

      assert ast ==
               {:if, [], [{:truthy?, [], [{:x, [], nil}]}, [do: 1]]}
    end

    test "BoolOp test gets the truthy? wrap (not bool-returning)" do
      bool_op_test = %{
        "_type" => "BoolOp",
        "op" => op("And"),
        "values" => [name("x"), name("y")]
      }

      {ast, _} = Converter.convert(if_node(bool_op_test, [const(1)]), Context.new())

      {:if, [], [test_ast, _]} = ast
      assert match?({:truthy?, [], [_]}, test_ast)
    end
  end

  describe "IfExp ternary" do
    test "if-expression emits if/else (always has both branches)" do
      ife = %{
        "_type" => "IfExp",
        "test" => compare(name("x"), "Gt", const(0)),
        "body" => const(1),
        "orelse" => const(-1)
      }

      {ast, _} = Converter.convert(ife, Context.new())

      assert ast ==
               {:if, [],
                [
                  {:py_gt, [], [{:x, [], nil}, 0]},
                  [do: 1, else: -1]
                ]}
    end
  end

  describe "end-to-end — values returned by if-statements" do
    # NOTE: Elixir's `if` is a scope barrier — assignments inside the body
    # do NOT leak to the enclosing scope. Threading assigned vars through
    # if-bodies (the same shape T16a does for `for` loops) is not in T15's
    # scope. These tests exercise the if's RETURN VALUE only.

    test "if-only with true condition returns the body's last expression" do
      ast = module_with([if_node(const(true), [const(42)])])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 42
    end

    test "if-only with false condition returns nil" do
      ast = module_with([if_node(const(false), [const(42)])])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == nil
    end

    test "Python-falsy [] routes correctly through truthy? wrap to the else branch" do
      empty_list = %{"_type" => "List", "elts" => []}
      ast = module_with([if_node(empty_list, [const("body")], [const("else")])])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == "else"
    end

    test "elif chain — first arm matching wins (using cond's return value)" do
      ast =
        module_with([
          assign([name("x")], const(5)),
          if_node(
            compare(name("x"), "Lt", const(0)),
            [const(-1)],
            [
              if_node(
                compare(name("x"), "Eq", const(0)),
                [const(0)],
                [const(1)]
              )
            ]
          )
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      assert value == 1
    end

    test "elif chain WITHOUT terminal else returns nil when nothing matches" do
      ast =
        module_with([
          assign([name("x")], const(5)),
          if_node(
            compare(name("x"), "Lt", const(0)),
            [const(-1)],
            [
              if_node(
                compare(name("x"), "Eq", const(0)),
                [const(0)]
              )
            ]
          )
        ])

      {_, value, _, _} = TranspileHelpers.transpile_and_run(ast)
      # No arm matches — `cond` returns nil via the synthetic `true -> nil`
      # fallthrough rather than raising CondClauseError.
      assert value == nil
    end

    test "IfExp ternary picks the right branch" do
      ife = %{
        "_type" => "IfExp",
        "test" => compare(const(10), "Gt", const(5)),
        "body" => const("big"),
        "orelse" => const("small")
      }

      {_, value, _, _} = TranspileHelpers.transpile_and_run(module_with([ife]))
      assert value == "big"
    end
  end
end
