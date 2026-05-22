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

  defp subscript(value, slice),
    do: %{"_type" => "Subscript", "value" => value, "slice" => slice}

  defp tuple(elts), do: %{"_type" => "Tuple", "elts" => elts}

  defp method_call(recv, attr, args),
    do: %{
      "_type" => "Expr",
      "value" => %{
        "_type" => "Call",
        "func" => %{"_type" => "Attribute", "value" => recv, "attr" => attr},
        "args" => args
      }
    }

  defp delete(targets), do: %{"_type" => "Delete", "targets" => targets}

  defp with_as(var, body),
    do: %{
      "_type" => "With",
      "items" => [%{"_type" => "withitem", "optional_vars" => var}],
      "body" => body
    }

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
    test "Assign inside a nested FunctionDef does NOT leak (walk_scope boundary), but the def's name does bind" do
      nested_def = %{
        "_type" => "FunctionDef",
        "name" => "helper",
        "body" => [assign(name("local"), const(0))]
      }

      outer = assign(name("outer"), const(0))
      analysis = LoopAnalysis.analyze([outer, nested_def])

      # `local` (inside the def body) is correctly hidden by the
      # walk_scope boundary. `helper` itself binds at the surrounding
      # scope — Pylixir emits nested FunctionDefs as `helper = fn ... end`,
      # so the state-tuple machinery must thread it like any other Assign.
      assert vars(analysis) == ["helper", "outer"]
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

  describe "target_in_place_mutated?/2 — propagating (TRUE)" do
    test "subscript assign: row[0] = 9" do
      body = [assign(subscript(name("row"), const(0)), const(9))]
      assert LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "nested subscript assign: row[i][j] = v" do
      body = [assign(subscript(subscript(name("row"), const(0)), const(1)), const(9))]
      assert LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "subscript aug-assign: row[1] += 10" do
      body = [aug_assign(subscript(name("row"), const(1)), "Add", const(10))]
      assert LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "slice assign: row[0:2] = xs" do
      slice = %{"_type" => "Slice", "lower" => const(0), "upper" => const(2)}
      body = [assign(subscript(name("row"), slice), name("xs"))]
      assert LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "method mutation depth 0: row.append(x)" do
      body = [method_call(name("row"), "append", [name("x")])]
      assert LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "method mutation depth 1: row[i].sort()" do
      body = [method_call(subscript(name("row"), const(0)), "sort", [])]
      assert LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "del row[i]" do
      body = [delete([subscript(name("row"), const(0))])]
      assert LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "mutation nested inside an If is still seen" do
      body = [if_node(const(true), [assign(subscript(name("row"), const(0)), const(9))])]
      assert LoopAnalysis.target_in_place_mutated?("row", body)
    end
  end

  describe "target_in_place_mutated?/2 — not propagating / wholesale (FALSE)" do
    test "no mutation at all" do
      refute LoopAnalysis.target_in_place_mutated?("row", [assign(name("x"), const(1))])
    end

    test "bare-Name rebind: row = [0, 0]" do
      body = [assign(name("row"), %{"_type" => "List", "elts" => []})]
      refute LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "bare-Name += is conservatively propagating under /2 (superset invariant)" do
      # /2 is typeless and used by promotion/fold gates; it must treat
      # `row += …` as a possible in-place mutation so its TRUE-set ⊇ /3's.
      body = [aug_assign(name("row"), "Add", name("xs"))]
      assert LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "co-occurrence: propagating AND wholesale ⇒ FALSE" do
      body = [
        assign(subscript(name("row"), const(0)), const(9)),
        assign(name("row"), %{"_type" => "List", "elts" => []})
      ]

      refute LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "nested `for row in …` rebinds row wholesale" do
      body = [for_node(name("row"), [assign(name("y"), const(1))])]
      refute LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "`with … as row` rebinds row wholesale" do
      body = [with_as(name("row"), [assign(subscript(name("row"), const(0)), const(9))])]
      refute LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "tuple-unpack of row is wholesale: row, b = pair" do
      body = [
        assign(subscript(name("row"), const(0)), const(9)),
        assign(tuple([name("row"), name("b")]), name("pair"))
      ]

      refute LoopAnalysis.target_in_place_mutated?("row", body)
    end

    test "mutation of a DIFFERENT name does not count" do
      body = [assign(subscript(name("other"), const(0)), const(9))]
      refute LoopAnalysis.target_in_place_mutated?("row", body)
    end
  end

  describe "target_in_place_mutated?/3 — type-gated bare-Name aug-assign" do
    @list {:list, :any}
    @set {:set}
    @dict {:dict, :any, :any}
    @int {:int}

    test "int += 1 is a no-op: must NOT rebuild (FALSE)" do
      body = [aug_assign(name("x"), "Add", const(1))]
      refute LoopAnalysis.target_in_place_mutated?("x", body, @int)
      refute LoopAnalysis.target_in_place_mutated?("x", body, :any)
    end

    test "list row += xs is in-place ⇒ TRUE" do
      body = [aug_assign(name("row"), "Add", name("xs"))]
      assert LoopAnalysis.target_in_place_mutated?("row", body, @list)
    end

    test "list row *= 2 is in-place ⇒ TRUE" do
      body = [aug_assign(name("row"), "Mult", const(2))]
      assert LoopAnalysis.target_in_place_mutated?("row", body, @list)
    end

    test "set ops |= &= -= ^= are in-place ⇒ TRUE" do
      for opn <- ["BitOr", "BitAnd", "Sub", "BitXor"] do
        body = [aug_assign(name("s"), opn, name("o"))]
        assert LoopAnalysis.target_in_place_mutated?("s", body, @set)
      end
    end

    test "dict d |= o is in-place ⇒ TRUE; d -= o is not a dict op ⇒ FALSE" do
      assert LoopAnalysis.target_in_place_mutated?(
               "d",
               [aug_assign(name("d"), "BitOr", name("o"))],
               @dict
             )

      refute LoopAnalysis.target_in_place_mutated?(
               "d",
               [aug_assign(name("d"), "Sub", name("o"))],
               @dict
             )
    end

    test "list += then wholesale rebind ⇒ FALSE (co-occurrence)" do
      body = [
        aug_assign(name("row"), "Add", name("xs")),
        assign(name("row"), %{"_type" => "List", "elts" => []})
      ]

      refute LoopAnalysis.target_in_place_mutated?("row", body, @list)
    end

    test "unknown elem type (:any) ⇒ bare += stays wholesale ⇒ FALSE" do
      body = [aug_assign(name("row"), "Add", name("xs"))]
      refute LoopAnalysis.target_in_place_mutated?("row", body, :any)
    end
  end

  describe "wholesale_rebinds?/2" do
    test "true for bare-Name rebind / for-target / with-as; false for += and subscript" do
      assert LoopAnalysis.wholesale_rebinds?("row", [assign(name("row"), const(0))])
      assert LoopAnalysis.wholesale_rebinds?("row", [for_node(name("row"), [])])
      assert LoopAnalysis.wholesale_rebinds?("row", [with_as(name("row"), [])])
      # `+=` is "maybe in-place", not a disconnecting wholesale rebind.
      refute LoopAnalysis.wholesale_rebinds?("row", [aug_assign(name("row"), "Add", const(1))])
      refute LoopAnalysis.wholesale_rebinds?("row", [
               assign(subscript(name("row"), const(0)), const(9))
             ])
    end
  end
end
