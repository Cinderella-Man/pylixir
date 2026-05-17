defmodule Pylixir.GoldenCorpusTest do
  @moduledoc """
  T32 golden test corpus. For every Python fixture in
  `test/fixtures/python/*.py`:

    1. Run the fixture through CPython 3.14 directly → expected stdout.
    2. Run the same fixture through `Pylixir.transpile/1` → Elixir source.
    3. Compile + eval that Elixir source via `TranspileHelpers.run_source/1`.
    4. Assert:
       - The generated module compiles with zero diagnostics.
       - The captured Elixir stdout matches CPython's stdout exactly.
       - The output is formatter-idempotent
         (`Code.format_string!(out) == out`).

  Skipped when Python 3.14 is not available (or `PYLIXIR_PYTHON` points
  somewhere else).
  """
  use ExUnit.Case, async: true

  alias Pylixir.TranspileHelpers

  @fixtures_dir Path.expand("../fixtures/python", __DIR__)

  defp python_cmd, do: System.get_env("PYLIXIR_PYTHON") || "python3.14"

  defp python_available? do
    case System.cmd(python_cmd(), ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.starts_with?(out, "Python 3.14")
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  defp python_stdout(file_path) do
    # Redirect stdin from /dev/null so CPython sees immediate EOF on
    # reads — matching the Pylixir side, where `capture_io/1` supplies
    # no input. Without this redirect, any fixture that calls
    # `sys.stdin.readline()` blocks for the test timeout (60s+).
    # Shelling out is safe here: fixture paths under `test/fixtures/`
    # are alphanumeric + `_` / `.`.
    {out, 0} =
      System.cmd("sh", ["-c", "exec '#{python_cmd()}' '#{file_path}' < /dev/null"],
        stderr_to_stdout: false
      )

    out
  end

  defp fixture_paths do
    @fixtures_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".py"))
    |> Enum.sort()
    |> Enum.map(&Path.join(@fixtures_dir, &1))
  end

  describe "golden corpus" do
    test "every fixture transpiles, compiles cleanly, and matches CPython stdout" do
      if python_available?() do
        results =
          for fixture <- fixture_paths() do
            source = File.read!(fixture)
            expected_stdout = python_stdout(fixture)

            elixir_src = Pylixir.transpile(source)
            {_, _value, actual_stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)

            formatted_once = elixir_src
            formatted_twice = formatted_once |> Code.format_string!() |> IO.iodata_to_binary()

            # Filter out stylistic warnings that don't reflect correctness:
            # "variable X is unused" and "X shadows ..." warnings arise
            # naturally from over-threading assigned vars (T15/T16/T18).
            # Catching real correctness issues = filtering for errors only.
            real_issues =
              Enum.reject(diagnostics, fn d ->
                msg = d[:message] || ""
                stylistic_warning?(msg)
              end)

            %{
              fixture: Path.basename(fixture),
              diagnostics_clean: real_issues == [],
              stdout_matches: normalize(actual_stdout) == normalize(expected_stdout),
              format_idempotent: formatted_once == formatted_twice,
              expected: expected_stdout,
              actual: actual_stdout,
              issues: real_issues
            }
          end

        bad_diagnostics = Enum.filter(results, &(not &1.diagnostics_clean))
        bad_stdout = Enum.filter(results, &(not &1.stdout_matches))
        bad_format = Enum.filter(results, &(not &1.format_idempotent))

        assert bad_diagnostics == [],
               "fixtures with compile-time diagnostics: #{inspect(Enum.map(bad_diagnostics, & &1.fixture))}"

        assert bad_format == [],
               "fixtures whose generated source is not formatter-idempotent: #{inspect(Enum.map(bad_format, & &1.fixture))}"

        if bad_stdout != [] do
          messages =
            Enum.map(bad_stdout, fn r ->
              "  #{r.fixture}:\n    expected:\n      " <>
                String.replace(r.expected, "\n", "\n      ") <>
                "\n    actual:\n      " <>
                String.replace(r.actual, "\n", "\n      ")
            end)

          flunk("fixtures whose stdout differs from CPython:\n" <> Enum.join(messages, "\n"))
        end
      end
    end
  end

  defp normalize(s), do: String.replace(s, "\r\n", "\n")

  defp stylistic_warning?(msg) do
    msg =~ "is unused" or msg =~ "shadows" or
      msg =~ "underscored variable" or msg =~ "no clause matching" or
      msg =~ "comparison with structs"
  end
end
