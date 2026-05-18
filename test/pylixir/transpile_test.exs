defmodule Pylixir.TranspileTest do
  @moduledoc """
  T33 acceptance tests for `Pylixir.transpile/1`: takes Python source,
  shells out to `python3.14`, parses the JSON envelope, dispatches to
  `to_source/1`. Negative paths surface as `Pylixir.PythonParseError` or
  `Pylixir.UnsupportedNodeError`, never as `Jason.DecodeError`.
  """
  use ExUnit.Case, async: true

  alias Pylixir.{PythonParseError, TranspileHelpers, UnsupportedNodeError}

  defp python_available? do
    python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

    case System.cmd(python, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.starts_with?(out, "Python 3.14")
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  describe "happy path" do
    test "print(1+1) compiles + evaluates to stdout `2`" do
      if python_available?() do
        elixir_src = Pylixir.transpile("print(1 + 1)\n")
        {_, _, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        assert stdout == "2\n"
        assert diagnostics == []
      end
    end

    test "an empty Python module yields a compiling, py_main-only output" do
      if python_available?() do
        out = Pylixir.transpile("")
        assert out =~ "defmodule TranslatedCode"
        assert out =~ "def py_main"
        assert out =~ "TranslatedCode.py_main()"
      end
    end
  end

  describe "negative paths surface cleanly" do
    test "unsupported node: `class A: pass` raises with `at line 1` in the message" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("class A: pass\n")
          end

        assert err.node_type == "ClassDef"
        assert err.message =~ "at line 1"
      end
    end

    test "Python syntax error raises `PythonParseError`, NOT `Jason.DecodeError`" do
      if python_available?() do
        err =
          assert_raise PythonParseError, fn ->
            Pylixir.transpile("def )\n")
          end

        # Whichever exact message Python emits, it carries a non-nil lineno.
        assert err.lineno != nil
      end
    end

    test "unregistered stdlib `import` raises with a clear hint listing knowns" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("import os\n")
          end

        assert err.node_type == "Import"
        assert err.hint =~ "import os"
        # The hint enumerates registered stdlib modules so the user knows
        # what *is* available. See `Pylixir.Stdlib.names/0`.
        assert err.hint =~ "math"
        assert err.hint =~ "sys"
      end
    end
  end

  describe "PYLIXIR_PYTHON env-var override" do
    test "default is `python3.14` and resolves" do
      if python_available?() do
        # If the default path didn't work, every preceding test would fail.
        # This test is essentially redundant but documents the contract.
        assert is_binary(Pylixir.transpile("42\n"))
      end
    end
  end

  describe "tagged unsupported literals from serialize.py" do
    test "complex literal `3+4j` raises with `complex` in the hint" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("3 + 4j\n")
          end

        assert err.hint =~ "complex"
      end
    end

    test "ASCII bytes literal is decoded as utf-8 (no rejection)" do
      # Pylixir doesn't model bytes vs str separately; the serializer
      # decodes b"..." as UTF-8 so most uses (bytes-as-text in
      # competitive code) just work.
      if python_available?() do
        out = Pylixir.transpile("b\"hello\"\n")
        assert out =~ "\"hello\""
      end
    end

    test "bytes literal lowers to a list of ints" do
      if python_available?() do
        # Bytes constants are now serialised as `list(obj)` (a list of
        # uint8 ints) — same backing rep `bytearray(iter)` uses. This
        # transpiles cleanly and `b"\\xff\\xfe"` reads as `[255, 254]`
        # in the generated module.
        out = Pylixir.transpile("print(b\"\\xff\\xfe\")\n")
        assert out =~ "[255, 254]"
      end
    end

    test "Ellipsis literal raises" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("...\n")
          end

        assert err.hint =~ "Ellipsis"
      end
    end
  end

  describe "unsupported Python builtins are caught at transpile time" do
    # Regression: bare calls to known-unsupported builtins (`iter`,
    # `next`, `eval`, ...) used to fall through the Call clause as
    # raw Elixir function references, producing opaque downstream
    # `undefined function iter/1` compile errors with no actionable
    # hint (eval-corpus bucket `compile_error--compile_quoted_raised`).
    # `Pylixir.Builtins.unsupported_hint/1` now flags them at transpile.

    test "`iter(xs)` lowers to py_iter_make (handle-backed cursor)" do
      if python_available?() do
        out = Pylixir.transpile("it = iter([1, 2, 3])\nprint(next(it))\n")
        assert out =~ "py_iter_make"
        assert out =~ "py_iter_next"
      end
    end

    test "`eval(s)` raises with `eval` hint" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("eval(\"1 + 1\")\n")
          end

        assert err.node_type == "Call"
        assert err.hint =~ "eval"
      end
    end

    test "`getattr(o, n)` raises with dynamic-attribute hint" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("getattr(x, \"a\")\n")
          end

        assert err.node_type == "Call"
        assert err.hint =~ "getattr"
      end
    end

    test "user `def` shadowing an unsupported builtin name is NOT rejected" do
      # If the user defines `def hash(x): return x`, calls to `hash(5)`
      # resolve to the local def and must reach the Name-in-scope clause
      # before the unsupported-builtin check fires. Without this, every
      # codebase that reused a builtin's name for its own helper would
      # break at transpile.
      if python_available?() do
        src = """
        def hash(x):
            return x + 1

        print(hash(5))
        """

        out = Pylixir.transpile(src)
        assert out =~ "defmodule TranslatedCode"
      end
    end

    test "`open(0).read()` still works — receiver-discard idiom preserved" do
      # `.read()` in attribute_methods.ex discards its receiver and
      # lowers to `py_stdin_read/0`, which is why `open(0).read()`
      # transpiles cleanly despite `open` being unsupported as
      # general file I/O. Rejecting `open` here would break the
      # competitive-code stdin idiom — see the comment on the
      # `@unsupported` map in `Pylixir.Builtins`.
      if python_available?() do
        out = Pylixir.transpile("data = open(0).read()\nprint(data)\n")
        assert out =~ "py_stdin_read"
      end
    end
  end

  describe "module-level dict mutated inside top-level def" do
    # Memoization shape: `memo = {…}` at module top, mutated via
    # `memo[k] = v` inside a top-level def. Originally rejected because
    # Pylixir lowers module-level literals to immutable Elixir module
    # attributes (the mutation would silently vanish). Now lowered
    # through the Erlang Process dict — reads emit `Process.get/1`,
    # writes emit `Process.put/2`, so mutations persist across calls
    # within the same py_main run. See ModuleAnalysis's
    # `mutable_module_dict_names` and Converter's
    # `process_dict_get_ast` / `_put_ast`.

    test "subscript-assign of a module dict inside a def transpiles + runs" do
      if python_available?() do
        src = """
        memo = {1: 1}

        def f(x):
            if x in memo:
                return memo[x]
            memo[x] = x * 2
            return memo[x]

        print(f(2))
        print(f(2))  # second call hits the cached value
        """

        out = Pylixir.transpile(src)
        # Confirm the lowering shape — every read/write of `memo`
        # routes through Process dict, no `@var_memo` attr left behind.
        assert out =~ "Process.put({:pylixir_mod, \"memo\"}"
        assert out =~ "Process.get({:pylixir_mod, \"memo\"})"
        refute out =~ "@var_memo"
      end
    end

    test "method-call mutation (.append) of a module list inside a def is also rejected" do
      if python_available?() do
        src = """
        items = []

        def push(x):
            items.append(x)

        push(1)
        print(items)
        """

        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile(src)
          end

        assert err.node_type == "Module"
        assert err.hint =~ "items"
      end
    end

    test "module dict that is only READ inside a def still works" do
      # The rejection must not over-fire: read-only access from a def
      # is a legitimate, common pattern (lookup tables, constants).
      if python_available?() do
        out =
          Pylixir.transpile("""
          table = {"a": 1, "b": 2}

          def lookup(k):
              return table[k]

          print(lookup("a"))
          print(lookup("b"))
          """)

        assert out =~ "@var_table"
        assert out =~ "def lookup"
      end
    end

    test "class instantiation and method calls transpile" do
      # The minimal data-class lowering: `Foo(args)` returns a map,
      # `obj.attr` reads via Map.fetch!, methods become defps. Covered
      # end-to-end by `test/fixtures/python/159_class_basic.py`;
      # repeated here as a transpile-only smoke check so the failure
      # mode is "the class lowering broke" rather than "the runtime
      # behaviour regressed".
      if python_available?() do
        out =
          Pylixir.transpile("""
          class Point:
              def __init__(self, x, y):
                  self.x = x
                  self.y = y
              def magnitude_sq(self):
                  return self.x * self.x + self.y * self.y
          p = Point(3, 4)
          print(p.magnitude_sq())
          """)

        assert out =~ "__cls_Point__init__"
        assert out =~ "__cls_Point_magnitude_sq"
        assert out =~ "Map.fetch!"
      end
    end

    test "class inheritance still rejected loudly" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("class B(A):\n    pass\n")
          end

        assert err.node_type == "ClassDef"
        assert err.hint =~ "inherits"
      end
    end

    test "def with a local rebinding (`name = ...`) of the module name is not rejected" do
      # Python's local-by-default: `name = ...` inside a def creates a
      # local that shadows the module-level. Subscript mutations of
      # that local don't reach the global, so the global remains
      # promotable.
      if python_available?() do
        out =
          Pylixir.transpile("""
          memo = {1: 1}

          def f():
              memo = {}
              memo[2] = 4
              return memo[2]

          print(f())
          """)

        assert out =~ "@var_memo"
      end
    end
  end
end
