defmodule Pylixir.ModuleAnalysisTest do
  use ExUnit.Case, async: true

  alias Pylixir.ModuleAnalysis

  defp const(value), do: %{"_type" => "Constant", "value" => value}
  defp name(id), do: %{"_type" => "Name", "id" => id}

  defp assign(target_id, value),
    do: %{"_type" => "Assign", "targets" => [name(target_id)], "value" => value}

  defp aug_assign(target, op_value),
    do: %{"_type" => "AugAssign", "target" => target, "value" => op_value}

  defp call(func, args), do: %{"_type" => "Call", "func" => func, "args" => args}

  defp expr_call(target_id, method, args),
    do: %{
      "_type" => "Expr",
      "value" =>
        call(
          %{"_type" => "Attribute", "value" => name(target_id), "attr" => method},
          args
        )
    }

  defp fn_def(name_str, body \\ []),
    do: %{"_type" => "FunctionDef", "name" => name_str, "body" => body}

  describe "analyze/1 — empty body" do
    test "all four facts default to empty" do
      analysis = ModuleAnalysis.analyze([])

      assert analysis.module_attrs == []
      assert analysis.function_defs == []
      assert analysis.runtime_statements == []
      assert MapSet.size(analysis.known_functions) == 0
    end
  end

  describe "analyze/1 — function defs" do
    test "collects every top-level FunctionDef name" do
      body = [fn_def("fib"), assign("x", const(1)), fn_def("main")]
      analysis = ModuleAnalysis.analyze(body)

      assert analysis.known_functions == MapSet.new(["fib", "main"])
      assert length(analysis.function_defs) == 2
    end

    test "nested function defs are NOT collected (walk_scope boundary)" do
      body = [
        fn_def("outer", [fn_def("inner")])
      ]

      analysis = ModuleAnalysis.analyze(body)

      assert analysis.known_functions == MapSet.new(["outer"])
    end
  end

  describe "analyze/1 — literal Assigns become module attrs when mutation-free" do
    test "scalar literal Assign with no later mutation → module_attr" do
      body = [assign("PI", const(3.14))]
      analysis = ModuleAnalysis.analyze(body)

      assert analysis.module_attrs == [{"PI", const(3.14)}]
      assert analysis.runtime_statements == []
    end

    test "list/tuple/dict literals also promote when mutation-free" do
      list_assign = assign("XS", %{"_type" => "List", "elts" => [const(1), const(2)]})
      tuple_assign = assign("YS", %{"_type" => "Tuple", "elts" => [const(:a), const(:b)]})

      dict_assign =
        assign("D", %{"_type" => "Dict", "keys" => [const("k")], "values" => [const(1)]})

      analysis = ModuleAnalysis.analyze([list_assign, tuple_assign, dict_assign])

      assert Enum.map(analysis.module_attrs, &elem(&1, 0)) == ["XS", "YS", "D"]
      assert analysis.runtime_statements == []
    end

    test "Assign with non-literal RHS does NOT promote" do
      # `Y = compute()` — RHS is a Call, not a literal.
      body = [assign("Y", call(name("compute"), []))]
      analysis = ModuleAnalysis.analyze(body)

      assert analysis.module_attrs == []
      assert length(analysis.runtime_statements) == 1
    end
  end

  describe "analyze/1 — mutation demotes literal Assigns to runtime" do
    test "direct reassignment downstream demotes" do
      body = [assign("X", const(1)), assign("X", const(2))]
      analysis = ModuleAnalysis.analyze(body)

      assert analysis.module_attrs == []
      assert length(analysis.runtime_statements) == 2
    end

    test "AugAssign downstream demotes" do
      body = [
        assign("X", const(0)),
        aug_assign(name("X"), const(1))
      ]

      analysis = ModuleAnalysis.analyze(body)

      assert analysis.module_attrs == []
    end

    test "subscript-target AugAssign demotes the root name" do
      # `d[k] += 1` — T14 rewrites to `d = ...`, so D must NOT promote.
      body = [
        assign("D", %{"_type" => "Dict", "keys" => [const("k")], "values" => [const(0)]}),
        aug_assign(
          %{"_type" => "Subscript", "value" => name("D"), "slice" => const("k")},
          const(1)
        )
      ]

      analysis = ModuleAnalysis.analyze(body)

      assert analysis.module_attrs == []
    end

    test "statement-context mutation method (.append) demotes" do
      body = [
        assign("XS", %{"_type" => "List", "elts" => []}),
        expr_call("XS", "append", [const(1)])
      ]

      analysis = ModuleAnalysis.analyze(body)

      assert analysis.module_attrs == []
    end

    test "for-loop target with the same name demotes" do
      body = [
        assign("I", const(0)),
        %{
          "_type" => "For",
          "target" => name("I"),
          "iter" => %{"_type" => "List", "elts" => []},
          "body" => []
        }
      ]

      analysis = ModuleAnalysis.analyze(body)

      assert analysis.module_attrs == []
    end

    test "non-mutation method (e.g., .lower) does NOT demote" do
      body = [
        assign("S", const("hello")),
        expr_call("S", "lower", [])
      ]

      analysis = ModuleAnalysis.analyze(body)

      assert Enum.map(analysis.module_attrs, &elem(&1, 0)) == ["S"]
    end
  end

  describe "analyze/1 — walk_scope boundary respect" do
    test "reassignment INSIDE a nested FunctionDef does NOT taint outer name" do
      # Python: inside def foo, `PI = 5` rebinds a LOCAL — module-level PI
      # stays constant. The mutation scan must respect scope.
      body = [
        assign("PI", const(3.14)),
        fn_def("foo", [assign("PI", const(5))])
      ]

      analysis = ModuleAnalysis.analyze(body)

      assert Enum.map(analysis.module_attrs, &elem(&1, 0)) == ["PI"]
    end
  end

  describe "analyze/1 — runtime_statements bucket" do
    test "non-literal Assigns and bare calls land in runtime_statements in order" do
      body = [
        assign("Y", call(name("compute"), [])),
        %{"_type" => "Expr", "value" => call(name("print"), [const("hi")])}
      ]

      analysis = ModuleAnalysis.analyze(body)

      assert length(analysis.runtime_statements) == 2
      assert hd(analysis.runtime_statements)["_type"] == "Assign"
    end
  end
end
