defmodule PylixirTest do
  use ExUnit.Case, async: true
  doctest Pylixir

  alias Pylixir.TranspileHelpers

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}

  @fixtures_dir Path.expand("fixtures/python", __DIR__)

  defp python_cmd, do: System.get_env("PYLIXIR_PYTHON") || "python3.14"

  defp python_available? do
    case System.cmd(python_cmd(), ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.starts_with?(out, "Python 3.14")
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  describe "to_source/1 on an empty Module — T05 acceptance" do
    test "produces a string containing the wrapper module + trailing call" do
      output = Pylixir.to_source(%{"_type" => "Module", "body" => []})

      assert is_binary(output)
      assert output =~ "defmodule TranslatedCode"
      assert output =~ "def py_main"
      assert output =~ "TranslatedCode.py_main()"
    end

    test "output compiles and runs with zero compiler warnings via transpile_and_run" do
      {_source, value, stdout, diagnostics} =
        TranspileHelpers.transpile_and_run(%{"_type" => "Module", "body" => []})

      # py_main on empty Module returns nil and emits nothing on stdout.
      assert value == nil
      assert stdout == ""

      assert diagnostics == [],
             "generated module produced unexpected diagnostics: " <> inspect(diagnostics)
    end
  end

  # Eval-corpus repro: `W, H = map(int, input().split())` produced Elixir
  # source `{W, H} = Enum.map(...)`, which the parser rejects because Elixir
  # treats ASCII-uppercase-leading identifiers as aliases, not variables.
  describe "to_source/1 — uppercase-leading Python identifiers" do
    test "tuple-unpacking into uppercase names compiles and runs cleanly" do
      ast = %{
        "_type" => "Module",
        "body" => [
          %{
            "_type" => "Assign",
            "targets" => [
              %{"_type" => "Tuple", "elts" => [name("W"), name("H")]}
            ],
            "value" => %{"_type" => "Tuple", "elts" => [const(3), const(4)]}
          },
          %{
            "_type" => "Expr",
            "value" => %{
              "_type" => "Call",
              "func" => name("print"),
              "args" => [name("W"), name("H")],
              "keywords" => []
            }
          }
        ]
      }

      {_source, _value, stdout, diagnostics} = TranspileHelpers.transpile_and_run(ast)

      assert diagnostics == []
      assert stdout == "3 4\n"
    end

    test "for-loop target with an uppercase name compiles and runs cleanly" do
      # `for I in [10, 20]: print(I)` — exercises a different binding site
      # (the for-loop target) than the tuple-unpack repro above.
      ast = %{
        "_type" => "Module",
        "body" => [
          %{
            "_type" => "For",
            "target" => name("I"),
            "iter" => %{"_type" => "List", "elts" => [const(10), const(20)]},
            "body" => [
              %{
                "_type" => "Expr",
                "value" => %{
                  "_type" => "Call",
                  "func" => name("print"),
                  "args" => [name("I")],
                  "keywords" => []
                }
              }
            ],
            "orelse" => []
          }
        ]
      }

      {_source, _value, stdout, diagnostics} = TranspileHelpers.transpile_and_run(ast)

      assert diagnostics == []
      assert stdout == "10\n20\n"
    end

    test "27_uppercase_var_unpack fixture transpiles end-to-end and matches CPython" do
      if python_available?() do
        fixture = Path.join(@fixtures_dir, "27_uppercase_var_unpack.py")
        python_src = File.read!(fixture)

        elixir_src = Pylixir.transpile(python_src)

        # Pin the alias-shape rewrite: bare `W`/`H` would be Elixir aliases;
        # the fix routes them through Naming Category 4 → `var_W`/`var_H`.
        assert elixir_src =~ "var_W"
        assert elixir_src =~ "var_H"

        {_, _value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
        assert errors == [], "compile errors: " <> inspect(errors)
        assert stdout == "12\n"
      end
    end
  end

  # Eval-corpus repro: `-float('inf')` raised "RFC §6.19 — Elixir has no
  # inf/nan". Fix: emit a large-magnitude sentinel float instead of
  # rejecting; works for the algorithmic min/max-finding idiom.
  describe "transpile/1 — float('inf') as a comparison sentinel" do
    test "37_float_inf_sentinel fixture transpiles end-to-end and matches CPython" do
      if python_available?() do
        fixture = Path.join(@fixtures_dir, "37_float_inf_sentinel.py")
        python_src = File.read!(fixture)

        elixir_src = Pylixir.transpile(python_src)

        # Pin the sentinel — both literal forms (with underscore from
        # the formatter) should appear.
        assert elixir_src =~ "1.0e308"
        assert elixir_src =~ "-1.0e308"

        {_, _value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
        assert errors == [], "compile errors: " <> inspect(errors)
        # 9 (max of the list), 1 (min), then three `True`s.
        assert stdout == "9\n1\nTrue\nTrue\nTrue\n"
      end
    end
  end

  # Eval-corpus repro: `adj[A].append(B)` raised "method `.append()` is
  # not supported" — Mutations only recognised bare-Name targets. Fix
  # adds a depth-1 subscript clause + matching ModuleAnalysis hook.
  describe "transpile/1 — subscript-rooted mutation methods" do
    test "36_subscript_mutation_methods fixture transpiles end-to-end and matches CPython" do
      if python_available?() do
        fixture = Path.join(@fixtures_dir, "36_subscript_mutation_methods.py")
        python_src = File.read!(fixture)

        elixir_src = Pylixir.transpile(python_src)

        # Pin the rebind shape: `adj = py_setitem(adj, …, py_getitem(adj, …) ++ …)`.
        assert elixir_src =~ ~r/py_setitem\(adj, 0, py_getitem\(adj, 0\)/

        # `adj` must NOT have been promoted to a module attribute.
        refute elixir_src =~ "@var_adj"

        {_, _value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
        assert errors == [], "compile errors: " <> inspect(errors)
        assert stdout == "[10, 20]\n[30]\n[]\n[]\n[100, 200, 300]\n"
      end
    end
  end

  # Eval-corpus repro: `set()` raised "`set/0` is not a supported Python
  # builtin call shape" — the zero-arg conversion-constructor form was
  # missing. Fix adds zero-arg clauses for the full
  # int/str/bool/float/list/tuple/set/dict family.
  describe "transpile/1 — zero-arg conversion constructors" do
    test "33_empty_constructors fixture transpiles end-to-end and matches CPython" do
      if python_available?() do
        fixture = Path.join(@fixtures_dir, "33_empty_constructors.py")
        python_src = File.read!(fixture)

        elixir_src = Pylixir.transpile(python_src)

        {_, _value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
        assert errors == [], "compile errors: " <> inspect(errors)
        # set() membership probe (1/0/1) + each empty-constructor's Python repr.
        assert stdout == "1\n0\n1\n0\n\nFalse\n0.0\n[]\n{}\n"
      end
    end
  end

  # Eval-corpus repro: `.copy()` raised "method not supported". Elixir's
  # immutability makes the copy identical to the value itself; the
  # existing mutation rewrites preserve the original. See
  # `Pylixir.Nodes.AttributeMethods.@noop_methods`.
  describe "transpile/1 — .copy() (immutability no-op)" do
    test "32_container_copy fixture transpiles end-to-end and matches CPython" do
      if python_available?() do
        fixture = Path.join(@fixtures_dir, "32_container_copy.py")
        python_src = File.read!(fixture)

        elixir_src = Pylixir.transpile(python_src)

        {_, _value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
        assert errors == [], "compile errors: " <> inspect(errors)

        # List: original unchanged, copy lost its 2. Dict: original
        # unchanged, copy's "a" became 99.
        assert stdout == "[1, 2, 3, 4]\n[1, 3, 4]\n1\n99\n"
      end
    end
  end

  # Eval-corpus repro: `for _ in xs:` inside an `if` body produced
  # `_ = if ... do _ else _ end` (the if/else state-tuple wrapper tried
  # to thread `_` through both branches). Elixir's `_` is pattern-only.
  describe "transpile/1 — underscore loop targets (discard semantics)" do
    test "31_underscore_loop_target fixture transpiles end-to-end and matches CPython" do
      if python_available?() do
        fixture = Path.join(@fixtures_dir, "31_underscore_loop_target.py")
        python_src = File.read!(fixture)

        elixir_src = Pylixir.transpile(python_src)

        # Pin the discard semantics: bare `_` patterns in the
        # for-loops, no `_ = if ...` state-tuple wrapper.
        assert elixir_src =~ ~r/fn _ ->/
        refute elixir_src =~ ~r/_ =\s+if /

        {_, _value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
        assert errors == [], "compile errors: " <> inspect(errors)
        assert stdout == "hi\nhi\nhi\n10\n20\ndone\n"
      end
    end
  end

  # Eval-corpus repro: `import sys` raised `UnsupportedNodeError("Import")`
  # because the Converter hardcoded `math` as the only allowed module name.
  # Fix: `Pylixir.Stdlib` registry — adding a new stdlib module is now one
  # new file + one `@implementations` entry.
  describe "transpile/1 — sys stdlib module (Pylixir.Stdlib.Sys)" do
    test "30_sys_module fixture transpiles end-to-end and matches CPython" do
      if python_available?() do
        fixture = Path.join(@fixtures_dir, "30_sys_module.py")
        python_src = File.read!(fixture)

        elixir_src = Pylixir.transpile(python_src)

        # Pin the registry-routed lowerings: sys.maxsize → literal, the
        # `if` enters because maxsize > 0, sys.exit(0) → throw, py_main's
        # catch surfaces the code. "unreachable" never prints. The
        # formatter inserts `_` separators in large int literals.
        assert elixir_src =~ "9_223_372_036_854_775_807"
        assert elixir_src =~ "throw({:pylixir_exit"

        {_, value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
        assert errors == [], "compile errors: " <> inspect(errors)
        assert stdout == "9223372036854775807\nnonempty\n"
        assert value == 0
      end
    end
  end

  # Eval-corpus repro: bare `exit()` lowered to `var_exit()` (undefined) —
  # `exit` collides with Kernel.exit/1 so Naming rewrites it, and there was
  # no Builtins emit clause to short-circuit. Fix adds an `exit` emit clause
  # that throws `:pylixir_exit` and a py_main try/catch that returns the code.
  describe "transpile/1 — exit() (Builtins emit + py_main catch wrapper)" do
    test "29_exit_early fixture transpiles end-to-end and matches CPython" do
      if python_available?() do
        fixture = Path.join(@fixtures_dir, "29_exit_early.py")
        python_src = File.read!(fixture)

        elixir_src = Pylixir.transpile(python_src)

        # Pin the lowering shape: exit() emits a tagged throw, py_main
        # catches and returns the code. Without both halves, the
        # generated module either fails to compile or runs past exit().
        assert elixir_src =~ "throw({:pylixir_exit"
        assert elixir_src =~ ":throw, {:pylixir_exit, code}"

        {_, value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
        assert errors == [], "compile errors: " <> inspect(errors)
        # `exit()` short-circuits: only the pre-exit print runs.
        assert stdout == "0\n"
        # py_main's catch surfaces the exit code (0 for bare `exit()`).
        assert value == 0
      end
    end
  end

  # Eval-corpus repro: `map(int, xs)` / `map(str, xs)` produced Elixir source
  # with bare `int` / `str` references (undefined variables). Pylixir's Call
  # router rewrites direct calls (`int(x) → py_int(x)`), but bare-Name uses
  # bypassed that rewrite. See Pylixir.Builtins.unary_capturable?/1.
  describe "transpile/1 — bare builtin references (Builtins.unary_capturable?)" do
    test "28_builtin_as_higher_order fixture transpiles end-to-end and matches CPython" do
      if python_available?() do
        fixture = Path.join(@fixtures_dir, "28_builtin_as_higher_order.py")
        python_src = File.read!(fixture)

        elixir_src = Pylixir.transpile(python_src)

        # Pin the bare-builtin capture: pre-fix, `map(int, ...)` lowered
        # to `Enum.map(..., int)` (undefined). The fix routes it to a
        # unary lambda — `fn x -> py_int(x)` is enough to prove the path.
        assert elixir_src =~ "fn x -> py_int(x)"
        assert elixir_src =~ "fn x -> py_str(x)"

        {_, _value, stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))
        assert errors == [], "compile errors: " <> inspect(errors)
        assert stdout == "10\n0 1 0 1 0\n"
      end
    end
  end
end
