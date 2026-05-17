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

    test "non-UTF-8 bytes literal still raises (decode fallback)" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("b\"\\xff\\xfe\"\n")
          end

        assert err.hint =~ "bytes"
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

    test "`iter(xs)` raises with `iter`/`next` hint" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("iter([1, 2, 3])\n")
          end

        assert err.node_type == "Call"
        assert err.hint =~ "iter"
        assert err.lineno == 1
      end
    end

    test "`next(it)` raises with `iter`/`next` hint" do
      if python_available?() do
        err =
          assert_raise UnsupportedNodeError, fn ->
            Pylixir.transpile("next(x)\n")
          end

        assert err.node_type == "Call"
        assert err.hint =~ "next"
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
end
