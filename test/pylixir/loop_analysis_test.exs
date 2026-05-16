defmodule Pylixir.LoopAnalysisTest do
  use ExUnit.Case, async: true

  alias Pylixir.LoopAnalysis

  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp op(n), do: %{"_type" => n}

  defp assign(target, value),
    do: %{"_type" => "Assign", "targets" => [target], "value" => value}

  defp aug_assign(target, op_name, value),
    do: %{"_type" => "AugAssign", "target" => target, "op" => op(op_name), "value" => value}

  defp for_node(target, body),
    do: %{
      "_type" => "For",
      "target" => target,
      "iter" => name("xs"),
      "body" => body,
      "orelse" => []
    }

  defp if_node(test, body, orelse \\ []),
    do: %{"_type" => "If", "test" => test, "body" => body, "orelse" => orelse}

  defp vars(analysis), do: MapSet.to_list(analysis.assigned_vars) |> Enum.sort()

  describe "analyze/1 — empty body" do
    test "empty body produces no assigned_vars" do
      assert vars(LoopAnalysis.analyze([])) == []
    end
  end

  describe "Assign targets" do
    test "single Name Assign" do
      analysis = LoopAnalysis.analyze([assign(name("total"), const(0))])
      assert vars(analysis) == ["total"]
    end

    test "Tuple-unpack Assign mentions every element" do
      tuple_target = %{"_type" => "Tuple", "elts" => [name("a"), name("b")]}

      analysis =
        LoopAnalysis.analyze([
          assign(tuple_target, %{"_type" => "Tuple", "elts" => [const(1), const(2)]})
        ])

      assert vars(analysis) == ["a", "b"]
    end

    test "Subscript target rebinds the root collection (T13 rewrites to setitem)" do
      target = %{"_type" => "Subscript", "value" => name("lst"), "slice" => const(0)}
      analysis = LoopAnalysis.analyze([assign(target, const(99))])

      assert vars(analysis) == ["lst"]
    end

    test "nested Subscript still resolves to the outermost root" do
      inner = %{"_type" => "Subscript", "value" => name("matrix"), "slice" => const(0)}
      target = %{"_type" => "Subscript", "value" => inner, "slice" => const(0)}
      analysis = LoopAnalysis.analyze([assign(target, const(99))])

      assert vars(analysis) == ["matrix"]
    end
  end

  describe "AugAssign targets" do
    test "Name AugAssign" do
      analysis = LoopAnalysis.analyze([aug_assign(name("total"), "Add", const(1))])
      assert vars(analysis) == ["total"]
    end

    test "Subscript AugAssign roots through to the collection" do
      target = %{"_type" => "Subscript", "value" => name("counts"), "slice" => name("k")}
      analysis = LoopAnalysis.analyze([aug_assign(target, "Add", const(1))])
      assert vars(analysis) == ["counts"]
    end
  end

  describe "nested control flow" do
    test "conditional Assign inside an If still contributes" do
      inner = assign(name("result"), const(42))
      analysis = LoopAnalysis.analyze([if_node(const(true), [inner])])
      assert vars(analysis) == ["result"]
    end

    test "Assign inside both arms of an If unions" do
      a = assign(name("a"), const(1))
      b = assign(name("b"), const(2))
      analysis = LoopAnalysis.analyze([if_node(const(true), [a], [b])])
      assert vars(analysis) == ["a", "b"]
    end

    test "nested For loop — body assigns are tracked; the loop target is NOT" do
      # For-loop targets are deliberately excluded (the loop emitter
      # puts them in an Enum.each / Enum.reduce lambda parameter, which
      # doesn't escape the loop's scope in Elixir). The body's
      # `inner_val = j` assign is still tracked.
      inner = for_node(name("j"), [assign(name("inner_val"), name("j"))])
      analysis = LoopAnalysis.analyze([inner])
      assert vars(analysis) == ["inner_val"]
    end
  end

  describe "scope barriers — FunctionDef inside the loop body" do
    test "Assign inside a nested FunctionDef does NOT leak (walk_scope boundary)" do
      nested_def = %{
        "_type" => "FunctionDef",
        "name" => "helper",
        "body" => [assign(name("local"), const(0))]
      }

      outer = assign(name("outer"), const(0))
      analysis = LoopAnalysis.analyze([outer, nested_def])

      assert vars(analysis) == ["outer"]
    end

    test "Assign inside a Lambda body does not leak" do
      lambda = %{
        "_type" => "Lambda",
        "args" => %{"args" => []},
        "body" => assign(name("inside_lambda"), const(1))
      }

      analysis = LoopAnalysis.analyze([assign(name("x"), lambda)])
      assert vars(analysis) == ["x"]
    end

    test "Assign inside a comprehension does not leak" do
      lc = %{
        "_type" => "ListComp",
        "elt" => name("i"),
        "generators" => []
      }

      analysis = LoopAnalysis.analyze([assign(name("xs"), lc)])
      assert vars(analysis) == ["xs"]
    end
  end

  describe "edge cases" do
    test "multiple assigns to the same name produce one entry (it's a Set)" do
      analysis =
        LoopAnalysis.analyze([
          assign(name("x"), const(1)),
          assign(name("x"), const(2)),
          assign(name("x"), const(3))
        ])

      assert vars(analysis) == ["x"]
    end

    test "deeply-nested If/For combo — body assigns kept, loop target dropped" do
      # As above: `k` is the loop target so it's excluded; `found` is
      # an Assign deep inside the if-branch body, still tracked.
      inner = assign(name("found"), const(true))
      inner_if = if_node(const(true), [inner])
      inner_for = for_node(name("k"), [inner_if])
      analysis = LoopAnalysis.analyze([inner_for])

      assert vars(analysis) == ["found"]
    end
  end
end
