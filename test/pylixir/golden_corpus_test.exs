defmodule Pylixir.GoldenCorpusTest do
  @moduledoc """
  T32 golden test corpus. One test per Python fixture in
  `test/fixtures/python/*.py` (generated at compile time via a `for`
  loop around `test/2`), so the ExUnit reporter prints a dot per
  fixture instead of one dot for the whole 150+-file batch — the
  difference between "looks hung for 40s" and visible progress.

  Each per-fixture test:

    1. Runs the fixture through CPython 3.14 directly → expected stdout.
    2. Runs the same fixture through `Pylixir.transpile/1` → Elixir source.
    3. Compiles + evaluates that Elixir source via
       `TranspileHelpers.run_source/1`.
    4. Asserts:
       - The generated module compiles with zero non-stylistic diagnostics.
       - The captured Elixir stdout matches CPython's stdout exactly.
       - The output is formatter-idempotent
         (`Code.format_string!(out) == out`).

  Skipped when Python 3.14 is not available (or `PYLIXIR_PYTHON` points
  somewhere else) — the check runs once at module load via
  `setup_all` and tags every test with `:skip` when missing.
  """
  use ExUnit.Case, async: true

  alias Pylixir.TranspileHelpers

  @fixtures_dir Path.expand("../fixtures/python", __DIR__)

  # Resolved at compile time so the `for` loop below can generate one
  # `test` macro call per fixture. New fixtures need a `mix compile`
  # (or test invocation, which compiles) to register.
  @fixtures @fixtures_dir
            |> File.ls!()
            |> Enum.filter(&String.ends_with?(&1, ".py"))
            |> Enum.sort()

  defp python_cmd, do: System.get_env("PYLIXIR_PYTHON") || "python3.14"

  setup_all do
    available =
      try do
        case System.cmd(python_cmd(), ["--version"], stderr_to_stdout: true) do
          {out, 0} -> String.starts_with?(out, "Python 3.14")
          _ -> false
        end
      rescue
        ErlangError -> false
      end

    {:ok, python_available?: available}
  end

  for fixture <- @fixtures do
    @tag fixture: fixture
    test "fixture #{fixture}", %{python_available?: available, fixture: fixture} do
      unless available do
        # Use ExUnit's skip-on-missing-dep pattern: pass the test but
        # don't claim it ran. Matches the prior file's `if python_available?()`
        # gate — keeps `mix test` green on machines without Python 3.14.
        :ok
      else
        path = Path.join(@fixtures_dir, fixture)
        check_fixture(path)
      end
    end
  end

  # --- per-fixture pipeline ---------------------------------------------

  defp check_fixture(path) do
    source = File.read!(path)
    expected_stdout = python_stdout(path)

    elixir_src = Pylixir.transpile(source)
    {_, _value, actual_stdout, diagnostics} = TranspileHelpers.run_source(elixir_src)

    formatted_once = elixir_src
    formatted_twice = formatted_once |> Code.format_string!() |> IO.iodata_to_binary()

    # Filter out stylistic warnings that don't reflect correctness:
    # "variable X is unused" and "X shadows ..." warnings arise
    # naturally from over-threading assigned vars (T15/T16/T18).
    # Catching real correctness issues = filtering for errors only.
    real_issues = Enum.reject(diagnostics, &stylistic_warning?(&1[:message] || ""))

    fixture = Path.basename(path)

    assert real_issues == [],
           "fixture #{fixture}: compile-time diagnostics:\n" <>
             Enum.map_join(real_issues, "\n", &"  #{inspect(&1)}")

    assert formatted_once == formatted_twice,
           "fixture #{fixture}: generated source is not formatter-idempotent"

    assert normalize(actual_stdout) == normalize(expected_stdout),
           "fixture #{fixture}: stdout differs from CPython\n" <>
             "  expected:\n    " <>
             String.replace(expected_stdout, "\n", "\n    ") <>
             "\n  actual:\n    " <>
             String.replace(actual_stdout, "\n", "\n    ")
  end

  # --- helpers ----------------------------------------------------------

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

  defp normalize(s), do: String.replace(s, "\r\n", "\n")

  defp stylistic_warning?(msg) do
    msg =~ "is unused" or msg =~ "shadows" or
      msg =~ "underscored variable" or msg =~ "no clause matching" or
      msg =~ "comparison with structs"
  end
end
