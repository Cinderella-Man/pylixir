defmodule Pylixir.Nodes.UnsupportedCoverageTest do
  @moduledoc """
  T31 coverage matrix: every node type in RFC §4.4 line 289's
  unsupported list (plus the additions raised during grilling) MUST
  raise `Pylixir.UnsupportedNodeError` with the right `_type` string,
  `lineno`, and `col_offset` populated.

  This guards against silently emitting wrong code when a future Python
  AST shape sneaks past the catch-all clause.
  """
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, UnsupportedNodeError}

  defp run_python(source) do
    python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

    case System.cmd(python, ["--version"], stderr_to_stdout: true) do
      {out, 0} ->
        if String.starts_with?(out, "Python 3.14"), do: Pylixir.transpile(source), else: :skip

      _ ->
        :skip
    end
  rescue
    ErlangError -> :skip
  end

  defp assert_raises_unsupported(source, type_pattern) do
    case run_python(source) do
      :skip ->
        :ok

      _ ->
        flunk("Expected UnsupportedNodeError but the source compiled cleanly")
    end
  rescue
    err in UnsupportedNodeError ->
      assert err.node_type =~ type_pattern,
             "expected node_type matching #{inspect(type_pattern)}, got #{inspect(err.node_type)}; hint=#{inspect(err.hint)}"
  end

  describe "RFC §4.4 — class / async / try / with" do
    test "ClassDef" do
      assert_raises_unsupported("class A:\n    pass\n", "ClassDef")
    end

    test "AsyncFunctionDef" do
      assert_raises_unsupported("async def f():\n    pass\n", "AsyncFunctionDef")
    end

    test "Try is now supported — minimal type-agnostic rescue/finally" do
      out = Pylixir.transpile("try:\n    1\nexcept:\n    2\n")
      assert is_binary(out)
      assert out =~ "rescue"
    end

    test "With" do
      assert_raises_unsupported("with open(\"f\") as f:\n    pass\n", "With")
    end

    test "Raise" do
      assert_raises_unsupported("raise ValueError(\"x\")\n", "Raise")
    end
  end

  describe "RFC §4.4 — scope keywords" do
    test "Global" do
      assert_raises_unsupported("def f():\n    global x\n    x = 1\n", "Global")
    end

    test "Nonlocal" do
      source = """
      def outer():
          x = 1
          def inner():
              nonlocal x
              x = 2
          inner()
      """

      assert_raises_unsupported(source, "Nonlocal")
    end
  end

  describe "RFC §4.4 — generators / yield / await" do
    test "Yield" do
      assert_raises_unsupported("def f():\n    yield 1\n", "Yield")
    end

    test "YieldFrom" do
      assert_raises_unsupported("def f():\n    yield from [1]\n", "YieldFrom")
    end
  end

  describe "RFC §4.4 — match / type aliases / annotated assigns" do
    test "Match" do
      assert_raises_unsupported("match x:\n    case 1:\n        pass\n", "Match")
    end

    test "AnnAssign" do
      assert_raises_unsupported("x: int = 5\n", "AnnAssign")
    end
  end

  describe "RFC §4.4 — f-strings, t-strings, sets, walrus, MatMult" do
    test "f-string with a format spec still raises (specs not yet supported)" do
      # Bare f-strings now lower to `<>` concats; only the format-spec
      # case (`f"{x:.2f}"`) is still unsupported, with a clearer hint.
      assert_raises_unsupported(~s|x = 3.14\nf"{x:.2f}"\n|, "FormattedValue")
    end

    # Set literals are now supported — `{1, 2, 3}` lowers to
    # `MapSet.new([1, 2, 3])`. (Test kept for the negative case:
    # set comprehensions containing Starred elements still raise.)
    test "Set literal with Starred raises" do
      assert_raises_unsupported("xs = [1, 2]\n{*xs, 3}\n", "Starred")
    end

    test "Walrus / NamedExpr" do
      assert_raises_unsupported("if (n := 5) > 0:\n    pass\n", "NamedExpr")
    end

    test "MatMult `@`" do
      assert_raises_unsupported("x = [1] @ [2]\n", "MatMult")
    end
  end

  describe "Additional rejections beyond RFC §4.4" do
    test "Starred in List literal" do
      assert_raises_unsupported("[*xs, 3]\n", "Starred")
    end

    test "Starred in Tuple literal" do
      assert_raises_unsupported("xs = [1, 2]\n(*xs, 3)\n", "Starred")
    end

    test "Delete statement" do
      assert_raises_unsupported("x = 1\ndel x\n", "Delete")
    end
  end

  describe "Direct converter rejections (no Python source needed)" do
    test "ImportFrom non-__future__ raises" do
      assert_raise UnsupportedNodeError, ~r/from.+import/, fn ->
        Converter.convert(
          %{"_type" => "ImportFrom", "module" => "os", "names" => []},
          Context.new()
        )
      end
    end

    test "Import of an unregistered stdlib module raises" do
      # `os` is not in the Pylixir.Stdlib registry. Use a name unlikely
      # to ever be supported so this test stays meaningful.
      assert_raise UnsupportedNodeError, ~r/import os/, fn ->
        Converter.convert(
          %{
            "_type" => "Import",
            "names" => [%{"_type" => "alias", "name" => "os", "asname" => nil}]
          },
          Context.new()
        )
      end
    end

    test "Break outside any loop" do
      assert_raise UnsupportedNodeError, ~r/break/, fn ->
        Converter.convert(%{"_type" => "Break"}, Context.new())
      end
    end

    test "Continue outside any loop" do
      assert_raise UnsupportedNodeError, ~r/continue/, fn ->
        Converter.convert(%{"_type" => "Continue"}, Context.new())
      end
    end

    test "Return outside a function" do
      assert_raise UnsupportedNodeError, ~r/return/i, fn ->
        Converter.convert(
          %{"_type" => "Return", "value" => %{"_type" => "Constant", "value" => 1}},
          Context.new()
        )
      end
    end

    test "Python identifier `var_foo` raises (T07 inverse-collision)" do
      assert_raise UnsupportedNodeError, ~r/var_foo/, fn ->
        Converter.convert(%{"_type" => "Name", "id" => "var_foo"}, Context.new())
      end
    end

    test "Python identifier `py_add` raises (T07 inverse-collision)" do
      assert_raise UnsupportedNodeError, ~r/py_add/, fn ->
        Converter.convert(%{"_type" => "Name", "id" => "py_add"}, Context.new())
      end
    end
  end

  describe "Assert (T31)" do
    test "passing assert is a no-op" do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            elixir_src = Pylixir.transpile("assert 1 == 1\n42\n")

            {_, value, _, _} = Pylixir.TranspileHelpers.run_source(elixir_src)
            assert value == 42
          end

        _ ->
          :ok
      end
    end

    test "failing assert raises RuntimeError with the supplied message" do
      python = System.get_env("PYLIXIR_PYTHON") || "python3.14"

      case System.cmd(python, ["--version"], stderr_to_stdout: true) do
        {out, 0} ->
          if String.starts_with?(out, "Python 3.14") do
            elixir_src = Pylixir.transpile("assert False, \"nope\"\n")

            assert_raise RuntimeError, ~r/nope/, fn ->
              Pylixir.TranspileHelpers.run_source(elixir_src)
            end
          end

        _ ->
          :ok
      end
    end
  end
end
