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
end
