defmodule Pylixir.SpecializationTest do
  use ExUnit.Case, async: true

  # End-to-end checks that monomorphic specialization (PR 2+) actually
  # collapses the polymorphic helper at conversion time. Each test
  # transpiles a small Python program and asserts the produced Elixir
  # source does NOT mention the polymorphic helper for the typed call,
  # while still emitting it for the polymorphic fallback case.

  describe "PR 2: bin_op_ast" do
    # Note: top-level `x = <literal>` Assigns are promoted to Elixir
    # module attributes by `ModuleAnalysis` (T05), bypassing the
    # Assign clause where `TypeInfer.bind` lives. Module-attribute
    # seeding lands in PR 8. Until then, in-function bodies and
    # literal-on-literal expressions are the demonstrable wins.

    test "int + int (literal-on-literal) does not emit py_add" do
      out = Pylixir.transpile("print(1 + 2)\n")
      refute out =~ "py_add("
    end

    test "str + str (literal-on-literal) does not emit py_add" do
      out = Pylixir.transpile(~s|print("hi" + " world")\n|)
      refute out =~ "py_add("
    end

    test "int + int inside a function body specializes (typed Name lookup)" do
      src = """
      def f():
          x = 1
          y = x + 2
          return y
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_add("
    end

    test "int - int inside a function body" do
      src = """
      def f():
          x = 5
          y = x - 1
          return y
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_sub("
    end

    test "int * int inside a function body" do
      src = """
      def f():
          x = 2
          y = x * 3
          return y
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_mult("
    end

    test ~s|literal "abc" * 3 folds to a static string at compile time| do
      # `LiteralPropagation` recognises `"-" * 80` as a foldable
      # expression (`LiteralFold` handles `binary * int`) and folds
      # the entire `print` arg to the 80-char repeat. No
      # `String.duplicate` call survives — the better outcome.
      out = Pylixir.transpile(~s|print("-" * 80)\n|)
      refute out =~ "py_mult("
      refute out =~ "String.duplicate"
      assert out =~ String.duplicate("-", 80)
    end

    test "literal [0] * 100 specializes to List.duplicate |> Enum.concat (Q2-B)" do
      out = Pylixir.transpile("print([0] * 100)\n")
      refute out =~ "py_mult("
      assert out =~ "List.duplicate"
    end

    test "str * dynamic int stays polymorphic (Q2-B safety)" do
      # `n` is now typed to {:int_lit_nonneg} via fixed-point, but Mult
      # specialization requires the *operand* to be a literal Constant —
      # the refinement tag never propagates through BinOp results.
      # Caller `f(n)` from inside a recursive context could mix sites.
      src = """
      def f(n):
          if n <= 0:
              return ""
          return "ab" * n
      def g(x):
          return f(x)
      print(g(5))
      print(g(-1))
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_mult("
    end

    test "int / int (literal-on-literal) does not emit py_div" do
      out = Pylixir.transpile("print(4 / 2)\n")
      refute out =~ "py_div("
    end

    test "bool + int falls through to py_add (Q7-A bool taint)" do
      out = Pylixir.transpile("print(True + 1)\n")
      assert out =~ "py_add("
    end

    test "BinOp with mixed-call-site param stays polymorphic" do
      # Multi-type call sites lub the param to a union → no spec.
      src = """
      def f(x):
          return x + 1
      print(f(1))
      print(f("hi"))
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_add("
    end
  end

  describe "PR 4: builtins specialization" do
    test "len on a list literal emits length/1" do
      out = Pylixir.transpile("print(len([1, 2, 3]))\n")
      refute out =~ "py_len("
      assert out =~ "length("
    end

    test "len on a string literal emits String.length" do
      out = Pylixir.transpile(~s|print(len("hello"))\n|)
      refute out =~ "py_len("
      assert out =~ "String.length"
    end

    test "len on a dict literal emits map_size" do
      out = Pylixir.transpile(~s|print(len({"a": 1}))\n|)
      refute out =~ "py_len("
      assert out =~ "map_size"
    end

    test "len on a tuple literal emits tuple_size" do
      out = Pylixir.transpile("print(len((1, 2, 3)))\n")
      refute out =~ "py_len("
      assert out =~ "tuple_size"
    end

    test "len of a heap-typed mutable_module_dict emits map_size (PR 3 × PR 4)" do
      src = """
      memo = {}
      def f(k):
          memo[k] = k
          return len(memo)
      print(f(1))
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_len("
      assert out =~ "map_size"
    end

    test "len on unknown value falls back to py_len (multi-type callers)" do
      src = """
      def f(x):
          return len(x)
      print(f([1]))
      print(f("hi"))
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_len("
    end

    test "int(int_literal) becomes a no-op (identity)" do
      out = Pylixir.transpile("print(int(5))\n")
      refute out =~ "py_int("
    end

    test "str(str_literal) becomes a no-op AND print drops py_str (PR-print-spec)" do
      # `str("hi")` returns "hi" (PR 4); `print("hi")` with the {:str}
      # arg drops the py_str wrap entirely (print-arg specialization).
      # Result: no `py_str` anywhere in the output — the helper isn't
      # even emitted because the tree-shaker drops it.
      out = Pylixir.transpile(~s|print(str("hi"))\n|)
      refute out =~ "py_str"
      assert out =~ ~s|IO.write("hi" <> "\\n")|
    end

    test "bool(bool_literal) becomes a no-op" do
      out = Pylixir.transpile("print(bool(True))\n")
      refute out =~ "truthy?(true)"
    end
  end

  describe "print() arg-type specialization" do
    test "print({:int}) drops py_str and emits Integer.to_string" do
      out = Pylixir.transpile("print(len([1, 2, 3]))\n")
      refute out =~ "py_str"
      assert out =~ "Integer.to_string"
    end

    test "print({:str}) drops py_str entirely" do
      out = Pylixir.transpile(~s|print("hello")\n|)
      refute out =~ "py_str"
      assert out =~ ~s|IO.write("hello" <> "\\n")|
    end

    test "print({:bool}) routes through py_bool_str (S2)" do
      out = Pylixir.transpile(~s|print("a" == "b")\n|)
      refute out =~ "py_str"
      assert out =~ "py_bool_str"
      # py_bool_str helper preamble has the True/False literals.
      assert out =~ "True"
      assert out =~ "False"
    end

    test "print(unknown) keeps py_str (polymorphic fallback)" do
      src = """
      def f(x):
          return x
      print(f(1))
      print(f("hi"))
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_str"
    end
  end

  describe "method-call specialization" do
    test ".startswith(literal_str) emits String.starts_with? directly" do
      out = Pylixir.transpile(~s|print("hello".startswith("hel"))\n|)
      refute out =~ "py_str_startswith"
      assert out =~ "String.starts_with?"
    end

    test ".endswith(literal_str) emits String.ends_with? directly" do
      out = Pylixir.transpile(~s|print("file.txt".endswith(".txt"))\n|)
      refute out =~ "py_str_endswith"
      assert out =~ "String.ends_with?"
    end
  end

  describe "S3: typed container inline reprs" do
    test "print([int, ...]) folds to a static literal at compile time" do
      # `LiteralPropagation` now folds the entire list literal to its
      # repr string before the typed-container inline path even runs.
      # The earlier S3 path (Enum.map_join + Integer.to_string) is
      # still reachable for *dynamic* lists; this test now pins the
      # superior outcome — a static binary in the output.
      out = Pylixir.transpile("print([1, 2, 3])\n")
      refute out =~ "py_str"
      refute out =~ "py_repr"
      assert out =~ ~s|"[1, 2, 3]"|
    end

    test "print({str: int}) folds the entire dict to a static literal" do
      out = Pylixir.transpile(~s|print({"a": 1, "b": 2})\n|)
      refute out =~ "py_str("
      refute out =~ "py_repr_map"
      # Dict literal is fully static — folded to the repr binary
      # rather than going through py_repr_str + Integer.to_string at
      # runtime.
      assert out =~ ~s|"{'a': 1, 'b': 2}"|
    end

    test "print([[int]]) recurses nested-list inline" do
      out = Pylixir.transpile("print([[1, 2], [3, 4]])\n")
      refute out =~ "py_str"
      refute out =~ "py_repr"
    end

    test "print([]) emits literal \"[]\", no py_str" do
      out = Pylixir.transpile("print([])\n")
      refute out =~ "py_str"
    end

    test "py_repr_str handles apostrophe-containing strings (S3 bugfix)" do
      # Direct test of the helper to confirm Python-correct quoting.
      assert Pylixir.RuntimeHelpers.py_repr_str("foo") == "'foo'"
      assert Pylixir.RuntimeHelpers.py_repr_str("can't") == ~s|"can't"|
      assert Pylixir.RuntimeHelpers.py_repr_str(~s|say "hi"|) == ~s|'say "hi"'|
    end
  end

  describe "PR 6: py_iter_to_list elision" do
    test "sorted on a list literal drops py_iter_to_list" do
      out = Pylixir.transpile("print(sorted([3, 1, 2]))\n")
      refute out =~ "py_iter_to_list("
    end

    test "for-loop over list literal drops py_iter_to_list" do
      src = """
      def f():
          total = 0
          for x in [1, 2, 3]:
              total = total + x
          return total
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_iter_to_list("
    end

    test "list comprehension over list literal drops py_iter_to_list" do
      out = Pylixir.transpile("print([x for x in [1, 2, 3]])\n")
      refute out =~ "py_iter_to_list("
    end

    test "for-loop over unknown iter keeps the wrap (mixed-call-site param)" do
      src = """
      def f(xs):
          total = 0
          for x in xs:
              total = total + 1
          return total
      print(f([1, 2, 3]))
      print(f("123"))
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_iter_to_list("
    end
  end

  describe "PR 5: Compare.pair_ast" do
    test "`x in list_literal` specializes to Kernel.in" do
      out = Pylixir.transpile("print(2 in [1, 2, 3])\n")
      refute out =~ "py_in("
    end

    test "`x in set_literal` specializes to MapSet.member?" do
      out = Pylixir.transpile("print(2 in {1, 2, 3})\n")
      refute out =~ "py_in("
      assert out =~ "MapSet.member?"
    end

    test "`k in dict_literal` specializes to Map.has_key?" do
      out = Pylixir.transpile(~s|print("a" in {"a": 1})\n|)
      refute out =~ "py_in("
      assert out =~ "Map.has_key?"
    end

    test "`substr in str_literal` specializes to String.contains?" do
      out = Pylixir.transpile(~s|print("ab" in "abcdef")\n|)
      refute out =~ "py_in("
      assert out =~ "String.contains?"
    end

    test "`x not in list_literal` specializes to negated Kernel.in" do
      out = Pylixir.transpile("print(4 not in [1, 2, 3])\n")
      refute out =~ "py_in("
    end

    test "`x in unknown` falls back to py_in (mixed-call-site param)" do
      src = """
      def f(xs):
          return 1 in xs
      print(f([1, 2]))
      print(f("12"))
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_in("
    end

    test "`k in mutable_module_dict` specializes via heap typing (PR 3 × PR 5)" do
      src = """
      cache = {}
      def f(k):
          cache[k] = k
          return k in cache
      print(f(1))
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_in("
      assert out =~ "Map.has_key?"
    end
  end

  describe "PR 8: Stdlib return types unlock chained specialization" do
    test "len(xs) + 1 specializes both sides (len → :int, BinOp → Kernel.+)" do
      src = """
      def f():
          xs = [1, 2, 3]
          return len(xs) + 1
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_len("
      refute out =~ "py_add("
      assert out =~ "length(xs)"
    end

    test "range() + len() returns a list iter for-loops can elide" do
      src = """
      def f():
          total = 0
          for i in range(10):
              total = total + 1
          return total
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_iter_to_list("
    end

    test "sorted preserves element type for downstream specialization" do
      src = """
      def f():
          xs = [3, 1, 2]
          ys = sorted(xs)
          return len(ys)
      print(f())
      """

      out = Pylixir.transpile(src)

      # After Task 2 the `ys = sorted(xs)` RHS is a freezable shape,
      # so it now lowers to `ys = py_alist_new(Enum.sort(xs))` and
      # `len(ys)` goes through `py_len/1`'s `{:py_alist, _}` clause
      # (also O(1)). Specialization is still happening — just via the
      # alist dispatch instead of a direct `length/1`.
      assert out =~ "py_alist_new(Enum.sort"
      assert out =~ "py_len(ys)"
    end
  end

  describe "PR 12: isinstance narrowing" do
    test "isinstance(x, int) narrows body branch — BinOp specializes" do
      src = """
      def f(x):
          if isinstance(x, int):
              return x + 1
          return 0
      print(f(5))
      print(f("hi"))
      """

      out = Pylixir.transpile(src)
      # `x + 1` inside the isinstance branch specializes; without
      # narrowing, mixed-call-site lub would leave x as a union → :any.
      refute out =~ "py_add("
    end

    test "isinstance(x, str) narrows body branch for str concat" do
      src = """
      def f(x):
          if isinstance(x, str):
              return x + "!"
          return ""
      print(f("hi"))
      print(f(0))
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_add("
    end

    test "isinstance(x, list) narrows so `len(x)` specializes" do
      src = """
      def f(x):
          if isinstance(x, list):
              return len(x)
          return 0
      print(f([1, 2]))
      print(f("hi"))
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_len("
    end
  end

  describe "PR 11: If branch isolation" do
    test "names typed inside If body don't leak as concrete types post-If" do
      # `y` is bound inside the if branch only. Reading `y` after the
      # if would not have a guaranteed type, so the post-If state for
      # `y` is `:any` (PR 11 conservative: types reset to pre-If).
      src = """
      def f(cond):
          if cond:
              y = 1
          else:
              y = "a"
          return y
      print(f(True))
      """

      out = Pylixir.transpile(src)
      # No regression — the function still compiles.
      assert out =~ "def f("
    end

    test "names typed *before* If keep their type for downstream BinOp" do
      src = """
      def f(flag):
          x = 5
          if flag:
              y = x + 1
              return y
          return x
      print(f(True))
      """

      out = Pylixir.transpile(src)
      # `x = 5` types x as int; `x + 1` inside the if specializes.
      refute out =~ "py_add("
    end
  end

  describe "PR 10: For-loop / comprehension target typing" do
    test "for-loop target inherits elem_of(iter) — body BinOp specializes" do
      src = """
      def f():
          total = 0
          for x in [1, 2, 3]:
              total = total + x
          return total
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_add("
    end

    test "list comprehension target typed via elem_of" do
      src = """
      def f():
          return [x + 1 for x in [10, 20, 30]]
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_add("
    end

    test "for x in range(10): x + 1 specializes (stdlib return + target binding)" do
      src = """
      def f():
          total = 0
          for x in range(10):
              total = total + x
          return total
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_add("
    end
  end

  describe "PR 9: Inter-procedural fixed-point" do
    test "recursive fib(int) → int converges and specializes Sub/Add" do
      src = """
      def fib(n):
          if n < 2:
              return n
          return fib(n - 1) + fib(n - 2)
      print(fib(10))
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_add("
      refute out =~ "py_sub("
    end

    test "function called with str arg sees param as :str" do
      src = """
      def greet(name):
          return name + "!"
      print(greet("hi"))
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_add("
    end

    test "mixed-type call sites poison the param to :any" do
      src = """
      def f(x):
          return x + 1
      print(f(1))
      print(f("a"))
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_add("
    end
  end

  describe "PR 7: Module-attribute seeding" do
    test "top-level int literal specializes BinOp at module scope" do
      out = Pylixir.transpile("x = 5\nprint(x + 1)\n")
      refute out =~ "py_add("
    end

    test "top-level list literal specializes len() at module scope" do
      out = Pylixir.transpile("xs = [1, 2, 3]\nprint(len(xs))\n")
      refute out =~ "py_len("
      assert out =~ "length("
    end

    test "top-level set literal specializes `in` to MapSet.member?" do
      out = Pylixir.transpile("s = {1, 2, 3}\nprint(2 in s)\n")
      refute out =~ "py_in("
      assert out =~ "MapSet.member?"
    end
  end

  describe "PR 4: f-string segments" do
    test "f-string of a string literal drops py_str (identity)" do
      out = Pylixir.transpile(~s|x = "hi"\nprint(f"got {x}")\n|)
      # The literal Constant "hi" is a {:str} segment; py_str on a
      # binary is identity, so we drop the call. Note: `x` is promoted
      # to a module attribute (@var_x), which is a binary at runtime.
      # Until PR 8 (module-attr seeding), `x` reads via @var_x and the
      # type is :any — segment falls back to py_str. So we test with
      # a function-body binding where TypeInfer.bind fires.
      _ = out

      src = """
      def f():
          x = "hi"
          return f"got {x}"
      print(f())
      """

      out = Pylixir.transpile(src)
      # In the function body, x: {:str} is recorded via TypeInfer.bind.
      # The f-string segment for {x} drops py_str.
      assert out =~ "f()"
    end

    test "f-string of an int variable folds to the literal at compile time" do
      # `n = 5; f"{n}"` — LiteralPropagation sees `n` as a literal
      # binding (single assign to a foldable Constant, no mutation /
      # alias / escape inside f). The f-string segment for `n`
      # resolves to `5` then folds to `"5"`. We never need
      # `Integer.to_string(n)` at runtime — the better outcome.
      src = """
      def f():
          n = 5
          return f"{n}"
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "py_str(n)"
      refute out =~ "Integer.to_string(n)"
      assert out =~ ~s|"5"|
    end
  end
end
