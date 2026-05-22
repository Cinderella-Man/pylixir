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

    test "for-loop over range(n) elides the surrounding Enum.to_list (Enum.reduce takes ranges directly)" do
      # `range(n)` lowers to `Enum.to_list(0..(n-1)//1)` so consumers
      # that need a concrete list (`len(r)`, `print(r)`) see one. But
      # `Enum.reduce` / `Enum.each` accept ranges directly — the wrap
      # is pure overhead in the for-loop iter slot. For n in the
      # hundreds of thousands (eval corpus `seed_13048` shape), the
      # avoided allocation is the difference between fitting and not
      # fitting under the 10s timeout.
      src = """
      def f(n):
          total = 0
          for j in range(n):
              total = total + 1
          return total
      print(f(10))
      """

      out = Pylixir.transpile(src)
      assert out =~ "Enum.reduce(0..(n - 1)//1,"
      refute out =~ "Enum.reduce(Enum.to_list(0..(n - 1)//1)"
    end

    test "for-loop over range(start, stop, -1) elides the wrap (reverse range)" do
      src = """
      def f(n):
          total = 0
          for j in range(n - 1, -1, -1):
              total = total + 1
          return total
      print(f(10))
      """

      out = Pylixir.transpile(src)
      assert out =~ "Enum.reduce((n - 1)..0//-1,"
      refute out =~ "Enum.reduce(Enum.to_list("
    end

    test "list comprehension over range elides the Enum.to_list wrap" do
      src = """
      def f(n):
          xs = [i * 2 for i in range(n)]
          return xs[5]
      print(f(10))
      """

      out = Pylixir.transpile(src)
      # `Enum.map(range, ...)` rather than `Enum.map(Enum.to_list(range), ...)`.
      assert out =~ "Enum.map(0..(n - 1)//1,"
      refute out =~ "Enum.map(Enum.to_list("
    end

    test "for-loop range elision preserves runtime correctness" do
      src = """
      def f(n):
          total = 0
          for j in range(n):
              total = total + j
          for j in range(n - 1, -1, -1):
              total = total + j
          return total
      print(f(100))
      """

      # `Pylixir.TranspileHelpers.run_source/1` strips the trailing
      # `TranslatedCode.py_main()` call before compiling and captures
      # `py_main`'s stdout cleanly. Doing a bare
      # `Code.compile_string(src)` would *execute* that trailing call
      # at compile time with no capture in place, leaking the program's
      # output into the test runner's stdout.
      {_, _, out, _} = Pylixir.TranspileHelpers.run_source(Pylixir.transpile(src))
      # sum(0..99) * 2 = 4950 * 2 = 9900
      assert out == "9900\n"
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

  describe "min/max 2-arg variadic uses Kernel.min/2, not Enum.min/1" do
    # In hot pvec loops (eval-corpus `seed_13048` shape:
    # `min_a[i] = min(a[i], min_a[i + 1])` n times), the 2-arg form
    # of `min`/`max` is the inner-loop cost driver. `Enum.min([a, b])`
    # builds a 2-element cons cell and walks it via `Enum.reduce` —
    # ~10 BEAM ops vs `Kernel.min/2`'s single guard.
    test "min(a, b) emits Kernel.min(a, b), not Enum.min" do
      src = """
      def f(x, y):
          return min(x, y)
      print(f(3, 7))
      """

      out = Pylixir.transpile(src)
      assert out =~ ~r/\bmin\(x, y\)/
      refute out =~ "Enum.min(["
    end

    test "max(a, b) emits Kernel.max(a, b), not Enum.max" do
      src = """
      def f(x, y):
          return max(x, y)
      print(f(3, 7))
      """

      out = Pylixir.transpile(src)
      assert out =~ ~r/\bmax\(x, y\)/
      refute out =~ "Enum.max(["
    end

    test "min(a, b, c) still uses Enum.min (3+ args)" do
      # 3-arg variadic still uses `Enum.min` since `Kernel.min/2`
      # doesn't generalize. Regression check that the 2-arg
      # specialization didn't break the variadic case.
      src = """
      def f(x, y, z):
          return min(x, y, z)
      print(f(3, 7, 1))
      """

      out = Pylixir.transpile(src)
      assert out =~ "Enum.min(["
    end

    test "2-arg variadic runtime correctness" do
      src = """
      def f():
          return [min(3, 7), max(3, 7), min(-5, -10), max("a", "b")]
      print(f())
      """

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(Pylixir.transpile(src))
      assert stdout == "[3, 7, -10, 'b']\n"
    end
  end

  describe "PvecAnalysis: `[d]*n` binds nested in loops/branches" do
    # `collect_pre_alloc_binds` originally scanned only top-level
    # statements, so an `arr = [0] * n` inside a `for`/`if` (the
    # eval-corpus seed_17116 shape — `original = [0]*n` rebuilt per
    # candidate, with `original[j] = …` writes) fell back to a plain
    # list with O(n) `List.replace_at` per write → O(n²)/O(n³).
    test "[0]*n bound inside a for-loop is pvec-detected" do
      src = """
      def f(n):
          result = 0
          for i in range(3):
              arr = [0] * n
              for j in range(n):
                  arr[j] = j
              result = result + arr[n - 1]
          return result
      print(f(5))
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_pvec_new(n, 0)"
      refute out =~ "py_mult([0]"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # arr = [0,1,2,3,4]; arr[4]=4; ×3 iterations → 12.
      assert stdout == "12\n"
    end

    test "[0]*n bound inside an if-branch is pvec-detected" do
      src = """
      def f(n, flag):
          if flag:
              arr = [0] * n
              for j in range(n):
                  arr[j] = j * 2
              return arr[n - 1]
          return -1

      print(f(4, 1))
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_pvec_new(n, 0)"
      refute out =~ "py_mult([0]"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # arr=[0,2,4,6]; arr[3]=6.
      assert stdout == "6\n"
    end
  end

  describe "PvecAnalysis: `return xs` doesn't disqualify pvec freeze" do
    # Eval-corpus `seed_14984` shape: a helper function builds a
    # `[0] * n` pvec, fills it via index-writes in a loop, then
    # `return`s it. Without admitting the bare-`Name` return as
    # safe, PvecAnalysis flagged it as a leak — the result lowered
    # to `py_mult([0], n)` (a plain Elixir list) and each `xs[i] = v`
    # became `List.replace_at` (O(n) per write) → O(n²) per call.
    # For n=10⁶ the testcase wedged the eval harness for minutes.

    test "helper returns the pvec; caller binds and indexes it" do
      src = """
      def f(n):
          xs = [0] * n
          for i in range(n):
              xs[i] = i + 1
          return xs

      def main():
          xs = f(5)
          return xs[3]

      print(main())
      """

      out = Pylixir.transpile(src)
      # The bind lowers to `py_pvec_new`, not `py_mult([0], n)`.
      assert out =~ "py_pvec_new(n, 0)"
      refute out =~ "py_mult([0]"
      # And the loop writes don't go through `List.replace_at`
      # (which is what the non-pvec fallback would emit).
      refute out =~ "List.replace_at"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      assert stdout == "4\n"
    end

    test "caller's iter-consuming ops on the returned pvec wrap correctly" do
      # Regression check for the issue exposed when ExampleInference
      # was on: the trace observed `compute_counts` returning a
      # Python list; without updating `fn_signatures` to reflect the
      # pvec lowering, the call-site bound the result as
      # `{:list, _}` and `Enum.max(count_x)` skipped the
      # `py_iter_to_list` wrap (per `coerce_iter`/`is_list?`) — at
      # runtime `count_x` was `{:py_pvec, _}` and Enum.max crashed.
      src = """
      def f(size):
          xs = [0] * size
          for i in range(size):
              xs[i] = i + 1
          return xs

      def main():
          xs = f(5)
          return max(xs) + sum(xs)

      print(main())
      """

      # `examples` enables ExampleInference, which is what surfaces
      # the underlying type-mismatch (trace observes Python `list`
      # return; Pylixir lowering produces `{:py_pvec, _}`).
      out = Pylixir.transpile(src, examples: [%{stdin: ""}])
      # The iter-consumers on the returned pvec must wrap with
      # `py_iter_to_list` (pvec isn't enumerable directly). The
      # trace observed `f` returning a Python list, but the lowering
      # produces a pvec — without the wrap, `Enum.max` crashes with
      # Protocol.UndefinedError at runtime.
      assert out =~ "Enum.max(py_iter_to_list(xs))"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # max(xs)=5, sum(xs)=15 → 20.
      assert stdout == "20\n"
    end

    test "caller iterates the returned pvec" do
      src = """
      def f(n):
          xs = [0] * n
          for i in range(n):
              xs[i] = i * i
          return xs

      def main():
          ys = f(10)
          total = 0
          for i in range(10):
              total = total + ys[i]
          return total

      print(main())
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_pvec_new(n, 0)"
      refute out =~ "py_mult([0]"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # sum(i*i for i in range(10)) = 0+1+4+9+16+25+36+49+64+81 = 285.
      assert stdout == "285\n"
    end
  end

  describe "pvec accumulator: raw :array threading through for-loop reduce" do
    # `[0] * n` + index-write loops are the eval-corpus `seed_13048`
    # hot path. The default lowering does `py_setitem({:py_pvec, _}, ..)`
    # per iter — a helper call (dispatch + pattern match) plus a
    # `{:py_pvec, ...}` tag-wrap allocation per write. For n in the
    # hundreds of thousands these allocations + dispatch are the
    # inner-loop cost driver. When the for-loop's reduce accumulator
    # is statically pvec AND the body uses it only via
    # `py_getitem(acc, k)` / `py_setitem(acc, k, v)`, the converter
    # unwraps to the raw `:array` once before the loop, threads the
    # array through the reduce, and rewraps once after.

    test "single-pvec write loop unwraps once, uses raw :array, rewraps once" do
      src = """
      def f(n):
          a = [0] * n
          for i in range(n):
              a[i] = i * 2
          return a[5]
      print(f(10))
      """

      out = Pylixir.transpile(src)
      # Pre-loop unwrap.
      assert out =~ ~r/\{:py_pvec, a_pvec_arr\} = a/
      # Loop body uses the raw-array helpers, not the wrapped ones.
      assert out =~ "py_pvec_arr_set(a_pvec_arr"
      refute out =~ ~r/Enum\.reduce\([^,]+, a, fn[^>]*->[^>]*py_setitem/
      # Post-loop rewrap.
      assert out =~ ~r/a = \{:py_pvec, a_pvec_arr\}/

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      assert stdout == "10\n"
    end

    test "pvec body with reads AND writes (suffix-min shape from seed_13048)" do
      src = """
      def f(n):
          a = [0] * n
          for i in range(n):
              a[i] = i + 1
          suffix_min = [0] * n
          suffix_min[n - 1] = a[n - 1]
          for i in range(n - 2, -1, -1):
              suffix_min[i] = min(a[i], suffix_min[i + 1])
          return suffix_min[0]
      print(f(5))
      """

      out = Pylixir.transpile(src)
      # Both loop bodies use the raw-array helpers for their pvec
      # accumulators. The cross-pvec read of `a` inside `suffix_min`'s
      # loop body stays as `py_getitem(a, _)` (a is not the
      # accumulator here). Regexes are whitespace-tolerant because
      # the formatter wraps long call arg lists.
      assert out =~ ~r/py_pvec_arr_set\(\s*a_pvec_arr/
      assert out =~ ~r/py_pvec_arr_set\(\s*suffix_min_pvec_arr/
      assert out =~ ~r/py_pvec_arr_get\(\s*suffix_min_pvec_arr/

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # a=[1,2,3,4,5]. suffix_min[4]=5; [3]=min(4,5)=4; [2]=min(3,4)=3;
      # [1]=min(2,3)=2; [0]=min(1,2)=1.
      assert stdout == "1\n"
    end

    test "non-subscript use of pvec accumulator bails (safety fallback)" do
      # `len(a)` reads the whole pvec, not via py_setitem/py_getitem
      # on the accumulator. The optimization must NOT apply or the
      # rewriter would lose the pvec wrapper. Falls back to the
      # default emission.
      src = """
      def f(n):
          a = [0] * n
          for i in range(n):
              a[i] = len(a) + i
          return a[0]
      print(f(3))
      """

      out = Pylixir.transpile(src)
      # The default emission is used (no unwrap/rewrap pair).
      refute out =~ ~r/\{:py_pvec, a_pvec_arr\} = a/

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # a[0] = len(a) + 0 = 3.
      assert stdout == "3\n"
    end

    test "uppercase-first Python name routes through Naming.rewrite (regression)" do
      # `A_pvec_arr` would parse as an Elixir *alias* (Module name),
      # not a variable, and the unwrap pattern match would silently
      # fail. Use `Naming.rewrite(var)` to build the array-side name
      # so it inherits the `var_`-prefix from the rewrite (e.g.
      # `A` → `var_A` → `var_A_pvec_arr`, lowercase-first → variable).
      src = """
      def f(n):
          A = [0] * n
          for i in range(n):
              A[i] = i * 3
          return A[2]
      print(f(5))
      """

      out = Pylixir.transpile(src)
      assert out =~ "var_A_pvec_arr"
      refute out =~ ~r/\{:py_pvec, A_pvec_arr\}/

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      assert stdout == "6\n"
    end

    test "read-only pvec in body (non-pvec accumulator) gets unwrapped before loop" do
      # The third loop in `seed_13048` sample 001: the accumulator
      # is `count` (int), but `min_a` (a `[0] * n` pvec) is *read*
      # inside the body. Without read-only specialization, every
      # `py_getitem(min_a, _)` dispatches through the helper. With
      # it, `min_a` is unwrapped once before the loop and reads use
      # the raw-array helper directly.
      src = """
      def f(n):
          xs = [0] * n
          for i in range(n):
              xs[i] = i * 10
          count = 0
          for j in range(n):
              if xs[j] > 50:
                  count = count + 1
          return count
      print(f(20))
      """

      out = Pylixir.transpile(src)
      # Read-only unwrap of xs before the second loop (no rewrap
      # since the value is unchanged).
      assert out =~ ~r/\{:py_pvec, xs_pvec_arr_ro\} = xs/
      # Body reads use the raw-array helper.
      assert out =~ "py_pvec_arr_get(xs_pvec_arr_ro"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # xs = [0, 10, 20, ..., 190]. Values > 50: 60, 70, ..., 190 → 14 values.
      assert stdout == "14\n"
    end

    test "pvec used both as accumulator AND read elsewhere combines both opts" do
      # The second loop in `seed_13048` sample 001: `min_a` is the
      # accumulator (write-spec applied) AND `a` is read in the body
      # (read-only-spec applied). Both unwraps should fire.
      src = """
      def f(n):
          a = [0] * n
          for i in range(n):
              a[i] = i + 1
          b = [0] * n
          for i in range(n - 1, -1, -1):
              b[i] = a[i] * 2
          return b[3]
      print(f(5))
      """

      out = Pylixir.transpile(src)
      # First loop: a as accumulator (write-spec).
      assert out =~ ~r/\{:py_pvec, a_pvec_arr\} = a/
      # Second loop: b as accumulator (write-spec) AND a as read-only.
      assert out =~ ~r/\{:py_pvec, b_pvec_arr\} = b/
      assert out =~ ~r/\{:py_pvec, a_pvec_arr_ro\} = a/
      assert out =~ "py_pvec_arr_get(a_pvec_arr_ro"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # a = [1,2,3,4,5]; b = [2,4,6,8,10]; b[3] = 8.
      assert stdout == "8\n"
    end

    test "read-only spec bails when pvec is also written in the body" do
      # If the body has `py_setitem(name, _, _)` for a name that's
      # NOT the accumulator, the read-only optimization can't apply
      # (the writes would lose their effect — no rewrap would
      # propagate the changes). Falls back to the generic emission.
      src = """
      def f(n):
          a = [0] * n
          b = [0] * n
          for i in range(n):
              b[i] = a[i] + 1
              a[i] = i  # writes to a — a is NOT read-only here
          return b[2]
      print(f(5))
      """

      out = Pylixir.transpile(src)
      # b should be accumulator-specialized (only its own assigns).
      # a should NOT be read-only-specialized (it has a write).
      refute out =~ "a_pvec_arr_ro"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # Per-iter (Python semantics, b is updated first, then a):
      # i=0: b[0]=a[0]+1=1; a[0]=0. i=1: b[1]=a[1]+1=1; a[1]=1. Etc.
      # b = [1,1,1,1,1]; b[2] = 1.
      assert stdout == "1\n"
    end

    test "non-pvec accumulator (no [0]*n pattern) is unaffected" do
      # Regression check: non-pvec accumulators stay on the default
      # `Enum.reduce(iter, acc, fn ... -> ... end)` emission.
      src = """
      def f():
          total = 0
          for i in range(10):
              total = total + i
          return total
      print(f())
      """

      out = Pylixir.transpile(src)
      refute out =~ "_pvec_arr"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      assert stdout == "45\n"
    end
  end

  describe "AppendBuildAnalysis: .sort() as tail finalizer" do
    test "xs = []; for: xs.append; xs.sort(); xs[0] avoids py_append fallback" do
      # Exact shape responsible for the `seed_13048` :elixir_timeout in
      # the eval corpus: build a list with .append inside a loop, then
      # .sort() it, then iterate read-only. Without the .sort() being
      # recognised as a tail finalizer, AppendBuildAnalysis bails and
      # the converter falls back to `py_append(xs, v) = xs ++ [v]` —
      # O(n) per call, O(n²) for the build.
      src = """
      def f():
          xs = []
          for v in range(1000):
              xs.append(v)
          xs.sort()
          return xs[0]
      print(f())
      """

      out = Pylixir.transpile(src)

      # O(1) prepend during build (`[v | xs]`), not O(n) `py_append`.
      refute out =~ "py_append(xs"

      # The .sort() statement still lowers to `xs = Enum.sort(xs)` —
      # operating on the reversed prepend-built list, which is fine
      # because plain .sort() (no key=) is order-independent on input.
      assert out =~ "Enum.sort(xs)"

      # After the sort, the freeze must NOT inject `Enum.reverse(xs)` —
      # reversing a sorted list de-sorts it. The lowered freeze is
      # `xs = py_alist_new(xs)`.
      assert out =~ "py_alist_new(xs)"
      refute out =~ "py_alist_new(Enum.reverse(xs))"
    end
  end

  describe "AlistAnalysis: self-concat rebind (`xs = [lit] + xs`)" do
    test "1-based-indexing idiom keeps xs as alist; indexed reads stay O(1)" do
      # The `seed_13048` sample 005 shape: `L = list(...); L = [0] + L`
      # to shift L to 1-based indexing. Without admitting the rebind as
      # freezable, L degrades to a plain list and `L[i]` becomes O(n)
      # → O(n²) total in any subsequent read loop. With the fix, both
      # binds wrap with `py_alist_new` and the rebind unwraps the prior
      # alist via `py_iter_to_list` before concatenating + refreezing.
      src = """
      def f():
          L = list(range(5))
          L = [0] + L
          return L[3]
      print(f())
      """

      out = Pylixir.transpile(src)
      # The rebind lowers to a single concat-then-freeze; the alist
      # gets unwrapped via `py_iter_to_list` before `++`.
      assert out =~ "var_L = py_alist_new([0] ++ py_iter_to_list(var_L))"
      # The original list( ) bind is also a freeze (existing behavior).
      assert out =~ ~r/var_L\s*=\s*py_alist_new\(/

      # Route the run through `TranspileHelpers.run_source/1` (strips
      # the trailing `TranslatedCode.py_main()` call before compiling
      # and captures stdout). A bare `Code.compile_string(out)` runs
      # the call uncaptured and leaks the program output into the
      # test runner's stdout.
      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # L after rebind: [0, 0, 1, 2, 3, 4]; L[3] = 2.
      assert stdout == "2\n"
    end

    test "xs + [lit] (append side) lowers symmetrically" do
      src = """
      def f():
          L = list(range(3))
          L = L + [-1]
          return L[3]
      print(f())
      """

      out = Pylixir.transpile(src)
      assert out =~ "var_L = py_alist_new(py_iter_to_list(var_L) ++ [-1])"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # L = [0, 1, 2, -1]; L[3] = -1.
      assert stdout == "-1\n"
    end
  end

  describe "next(iter(x)) coerces through py_iter_to_list" do
    # `next(iter(x))` is specialized to `Enum.fetch!(x, 0)`. For a
    # list/string the first element is correct, but for a dict
    # Python's `iter(dict)` yields KEYS — `Enum.fetch!(map, 0)`
    # returns a `{k, v}` entry instead. Coerce through
    # `py_iter_to_list` (which maps to `Map.keys/1` for maps) so the
    # dict case yields the first key. Surfaces in the
    # `Counter - Counter` → `next(iter(diff))` eval-corpus shape
    # (seed_1726 / seed_17225).
    test "next(iter(dict)) yields the first key, not a {k,v} entry" do
      src = """
      def f():
          d = {7: 100}
          return next(iter(d))
      print(f())
      """

      out = Pylixir.transpile(src)
      assert out =~ "py_iter_to_list"

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      assert stdout == "7\n"
    end

    test "next(iter(list)) still yields the first element" do
      src = """
      def f():
          return next(iter([42, 43, 44]))
      print(f())
      """

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(Pylixir.transpile(src))
      assert stdout == "42\n"
    end
  end

  describe "AlistAnalysis: `==`/`!=` comparison doesn't disqualify alist freeze" do
    # eval-corpus seed_19498: `a = list(...); sorted_a = sorted(a);
    # if a == sorted_a: ...` then `a[i]` reads in a loop. Treating
    # `==` as a leak left `a` a plain list → O(n) `Enum.at` per
    # index → O(n²) loop. `==`/`!=` are value comparisons; `py_eq`
    # normalizes the alist representation, so it's safe to keep `a`
    # frozen and route the comparison through `py_eq`.
    test "list compared with == still freezes to alist; comparison uses py_eq" do
      src = """
      def f():
          a = list(map(int, "3 1 2".split()))
          s = sorted(a)
          if a == s:
              return -1
          return a[0] + a[1] + a[2]
      print(f())
      """

      out = Pylixir.transpile(src)
      # `a` freezes to alist.
      assert out =~ "py_alist_new"
      # The comparison routes through py_eq (alist-aware), not raw ==.
      assert out =~ "py_eq("

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(out)
      # a=[3,1,2], s=[1,2,3]; a != s → 3+1+2 = 6.
      assert stdout == "6\n"
    end

    test "equal case returns true through py_eq" do
      src = """
      def f():
          a = list(map(int, "1 2 3".split()))
          s = sorted(a)
          return 1 if a == s else 0
      print(f())
      """

      {_, _, stdout, _} = Pylixir.TranspileHelpers.run_source(Pylixir.transpile(src))
      assert stdout == "1\n"
    end

    test "alist == non-iterable scalar is False, not a crash" do
      # py_eq must not call py_iter_to_list on the scalar side.
      assert Pylixir.RuntimeHelpers.py_eq(Pylixir.RuntimeHelpers.py_alist_new([1, 2]), 5) == false
      assert Pylixir.RuntimeHelpers.py_eq(5, Pylixir.RuntimeHelpers.py_alist_new([1, 2])) == false
    end
  end
end
