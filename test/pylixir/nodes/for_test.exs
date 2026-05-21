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

    test "tuple-unpack target over list-of-lists: emits list pattern, runs correctly" do
      # `for s, e in [[1, 2], [3, 4]]:` is valid Python — sequence
      # unpacking works on any iterable of length 2, including lists.
      # The naive lowering emits `fn {s, e} -> ...` (tuple pattern),
      # which fails at runtime with FunctionClauseError on a list
      # element. The type-directed fix: when the iterable's element
      # type is `{:list, _}`, emit `fn [s, e] -> ...` instead.
      src = """
      def f():
          total = 0
          for s, e in [[1, 2], [3, 4]]:
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      assert elixir_src =~ "fn [s, e]"
      refute elixir_src =~ "fn {s, e}"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      assert diagnostics == []
      assert stdout == "10\n"
    end

    test "tuple-unpack target over list-of-tuples: tuple pattern preserved (regression)" do
      # Tuple-element iterables must keep the tuple pattern — Elixir
      # tuples are `{a, b}` and that's what's actually in the list.
      src = """
      def f():
          total = 0
          for s, e in [(1, 2), (3, 4)]:
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      assert elixir_src =~ "fn {s, e}"
      refute elixir_src =~ "fn [s, e]"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      assert diagnostics == []
      assert stdout == "10\n"
    end

    test "append-built list-of-lists: element type propagates → list pattern" do
      # Mirrors the failing `seed_13048` eval sample's shape: build
      # `merged` via `merged.append([s, e])` in a loop, then iterate
      # `for s, e in merged:`. Without element-type propagation through
      # `.append`, `merged` demotes to `{:list, :any}` and the loop
      # falls back to the tuple pattern → FCE at runtime on the
      # 2-element list elements.
      src = """
      def f():
          merged = []
          merged.append([1, 2])
          merged.append([3, 4])
          total = 0
          for s, e in merged:
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      assert elixir_src =~ "fn [s, e]"
      refute elixir_src =~ "fn {s, e}"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      assert diagnostics == []
      assert stdout == "10\n"
    end

    test "append-built list-of-lists then sorted (full seed_13048 shape)" do
      # End-to-end: AppendBuildAnalysis admits .sort() as a tail
      # finalizer (prior change), and refine-after-append propagates
      # the element type through to the iterating loop.
      src = """
      def f():
          merged = []
          merged.append([3, 4])
          merged.append([1, 2])
          merged.sort()
          total = 0
          for s, e in merged:
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      assert elixir_src =~ "fn [s, e]"
      refute elixir_src =~ "fn {s, e}"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      assert diagnostics == []
      assert stdout == "10\n"
    end

    test "append-built list-of-tuples: tuple pattern (regression — refinement preserves tuple element)" do
      # Same .append-build shape but with tuple elements. Element type
      # propagation should land at `{:list, {:tuple, _}}`, NOT
      # `{:list, {:list, _}}`, so the loop keeps the tuple pattern.
      src = """
      def f():
          pairs = []
          pairs.append((1, 2))
          pairs.append((3, 4))
          total = 0
          for s, e in pairs:
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      assert elixir_src =~ "fn {s, e}"
      refute elixir_src =~ "fn [s, e]"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      assert diagnostics == []
      assert stdout == "10\n"
    end

    test "append-built mixed list/tuple elements: refinement lubs to :any → tuple pattern (safe)" do
      # When .append targets disagree on element shape, the lub widens
      # to `:any` and we fall back to the current tuple-pattern default.
      # The test fixes the iterable to contain only tuples (so the
      # tuple pattern actually runs), but the *element type* tracked
      # for `mixed` is `:any` because of the list/tuple disagreement.
      src = """
      def f():
          mixed = []
          mixed.append([1, 2])
          mixed.append((3, 4))
          mixed.pop()
          mixed.pop()
          mixed.append((5, 6))
          total = 0
          for s, e in mixed:
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      # Lub-widened element type → safe-default tuple pattern.
      assert elixir_src =~ "fn {s, e}"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      assert diagnostics == []
      assert stdout == "11\n"
    end

    test "append-built with nested subscript-assign on element: type-preserving, list pattern" do
      # `xs[-1][1] = v` modifies the INSIDE of an existing element —
      # the element shape (a 2-list) and xs's element TYPE are
      # unchanged. The `seed_13048` eval sample's `merged` exactly hits
      # this pattern: without admitting nested subscript-assigns as
      # type-preserving, `merged`'s element type can't be tracked
      # through the build region and the third for-loop falls back to
      # the tuple pattern → FCE on the list elements.
      src = """
      def f():
          xs = []
          xs.append([1, 2])
          xs.append([3, 4])
          xs[-1][1] = 99
          total = 0
          for s, e in xs:
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      assert elixir_src =~ "fn [s, e]"
      refute elixir_src =~ "fn {s, e}"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      assert diagnostics == []
      # 1 + 2 + 3 + 99 = 105
      assert stdout == "105\n"
    end

    test "seed_13048 third-loop shape: build-with-subscript-mutate then iterate" do
      # End-to-end of the eval corpus's `seed_13048` failure shape (the
      # `merged` build + read). The build region has reads interleaved
      # with appends (`last_s, last_e = merged[-1]`) AND nested
      # subscript-assigns (`merged[-1][1] = …`). AppendBuildAnalysis
      # correctly bails the alist-freeze for this shape; element-type
      # tracking still admits it because every value-adding op is
      # `.append(list_literal)` and the other ops are type-preserving.
      src = """
      def f():
          intervals = [(1, 3), (5, 7), (6, 8), (10, 12)]
          merged = []
          for s, e in intervals:
              if not merged:
                  merged.append([s, e])
              else:
                  last_s, last_e = merged[-1]
                  if s > last_e + 1:
                      merged.append([s, e])
                  else:
                      merged[-1][1] = max(e, last_e)
          total = 0
          for s, e in merged:
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      assert elixir_src =~ "fn [s, e]"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      # The Python source has `last_s, last_e = merged[-1]` with only
      # `last_e` used; Pylixir faithfully destructures both, Elixir
      # warns about the unused binding. That's pre-existing emission
      # behavior unrelated to this change — filter out warnings.
      errors = Enum.reject(diagnostics, &(&1.severity == :warning))
      assert errors == []
      # Trace: (1,3) → [[1,3]]. (5,7): 5>3+1=4 → [[1,3],[5,7]]. (6,8):
      # 6>7+1=8 no → max(8,7)=8 → [[1,3],[5,8]]. (10,12): 10>8+1=9 →
      # [[1,3],[5,8],[10,12]]. total = 4 + 13 + 22 = 39.
      assert stdout == "39\n"
    end

    test "direct subscript-assign xs[i] = v: replaces element, type tracking bails (safe-default tuple pattern)" do
      # Direct `xs[i] = new_value` replaces an element entirely — the
      # element type could differ from the .append args. The lenient
      # type-refinement should NOT admit this case, so the loop falls
      # back to the safe-default tuple pattern. The iterable is fixed
      # to actually contain tuples at runtime so the assertion is
      # meaningful.
      src = """
      def f():
          xs = []
          xs.append([1, 2])
          xs[0] = (9, 9)
          total = 0
          for s, e in xs:
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      # Direct subscript-assign disqualifies the name from type
      # refinement → loop falls back to tuple pattern.
      assert elixir_src =~ "fn {s, e}"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      assert diagnostics == []
      # xs after direct assign = [(9, 9)]; total = 18.
      assert stdout == "18\n"
    end

    test "tuple-unpack target with unknown iterable element type: tuple pattern (safe default)" do
      # When the iterable comes from a function call whose return type
      # we don't track precisely, `elem_of` yields `:any` — the loop
      # target keeps the tuple pattern (current behavior). Users with
      # genuinely mixed iterables remain on the existing semantics; the
      # fix is purely additive for the cases where the element type is
      # provably a list.
      src = """
      def make():
          return [(1, 2), (3, 4)]
      def f():
          total = 0
          for s, e in make():
              total = total + s + e
          return total
      print(f())
      """

      elixir_src = Pylixir.transpile(src)
      assert elixir_src =~ "fn {s, e}"

      {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
      assert diagnostics == []
      assert stdout == "10\n"
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
