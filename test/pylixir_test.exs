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
  end
end
