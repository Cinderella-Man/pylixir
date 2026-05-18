defmodule Pylixir.SlimmingTest do
  @moduledoc """
  Per-fixture slimming-regression tests. Each entry in `@fixtures`
  names a file in `test/fixtures/slimming/` and encodes the
  helper-absence / helper-presence claims its header doc-comment
  makes, plus the expected stdout from running the transpiled
  program.

  Why a separate test file vs. the golden corpus:
    * `golden_corpus_test.exs` checks **correctness** end-to-end —
      stdout matches CPython. It does not care whether the output
      pulled in `py_mod` or `Integer.mod`, only that the answer is
      right.
    * This file checks **slimness** — that previously-eliminated
      helper cascades stay eliminated. A regression in
      `bin_op_ast`'s int-specialisation (or in tree-shaking) would
      keep CPython parity but quietly re-inflate output. Pinning
      the helper-absence here catches that.

  When you add a new slimming fixture:
    1. Drop the `.py` in `test/fixtures/slimming/`.
    2. Add an `@fixtures` entry naming the substrings that MUST /
       MUST NOT appear in the transpiled output, the expected
       stdout, and (optionally) a `max_lines` ceiling.

  Optional invariant keys per fixture:
    * `:must_not_contain` — list of substrings forbidden in output.
    * `:must_contain` — list of substrings required in output.
    * `:max_lines` — output line-count ceiling (slim ratchet).
    * `:stdout` — exact stdout from running the transpiled program.
  """
  use ExUnit.Case, async: true

  alias Pylixir.TranspileHelpers

  @fixtures_dir Path.expand("../fixtures/slimming", __DIR__)

  @fixtures %{
    "01_typed_bool_prints.py" => %{
      must_not_contain: ["py_truthy?"],
      must_contain: ["py_bool_str"],
      stdout: "True\nTrue\nTrue\nTrue\nyes\nyes\n"
    },
    "02_typed_int_list.py" => %{
      # S3 typed-list inline + LiteralPropagation: literal lists fold
      # to static binaries; no py_str / py_repr referenced anywhere.
      must_not_contain: ["py_str", "py_repr"],
      stdout: "[1, 2, 3]\n[10, 20, 30]\n[]\n[4, 5, 6]\n"
    },
    "03_typed_dict.py" => %{
      must_not_contain: ["py_str", "py_repr"],
      # Pylixir's dict iteration is BEAM-map-order; for these small
      # literals the order happens to match what Python prints.
      stdout: """
      {'a': 1, 'b': 2}
      {'x': 10}
      {}
      {'city': 'boston', 'name': 'alice'}
      """
    },
    "04_nested_containers.py" => %{
      must_not_contain: ["py_str", "py_repr"]
    },
    "05_isinstance_narrowed_bool.py" => %{
      must_not_contain: ["py_truthy?", "py_str", "py_repr"]
    },
    "08_isinstance_or.py" => %{
      must_not_contain: ["py_truthy?"]
    },
    "10_fizzbuzz_int_mod.py" => %{
      # Cascade regression: `int % int` MUST emit `Integer.mod`, not
      # `py_mod`. With py_mod gone, the entire percent-format helper
      # chain (and the py_str / py_repr it pulls) tree-shakes out.
      must_not_contain: [
        "py_mod",
        "py_floor_div",
        "py_str_percent_format",
        "format_percent_typed",
        "parse_percent",
        "apply_percent",
        "apply_zero_pad",
        "py_str",
        "py_repr"
      ],
      must_contain: ["Integer.mod", "Integer.to_string"],
      max_lines: 20,
      stdout:
        "1\n2\nFizz\n4\nBuzz\nFizz\n7\n8\nFizz\nBuzz\n11\nFizz\n13\n14\nFizzBuzz\n"
    }
  }

  for {fixture, invariants} <- @fixtures do
    @tag fixture: fixture
    test "slim regression: #{fixture}", %{fixture: fixture} do
      check_slimming(fixture, unquote(Macro.escape(invariants)))
    end
  end

  defp check_slimming(fixture, invariants) do
    src_path = Path.join(@fixtures_dir, fixture)
    src = File.read!(src_path)
    out = Pylixir.transpile(src)

    for substr <- Map.get(invariants, :must_not_contain, []) do
      refute out =~ substr,
             """
             #{fixture}: transpile output unexpectedly contains #{inspect(substr)}.
             A helper that should have been eliminated has crept back in.
             Output:
             #{out}
             """
    end

    for substr <- Map.get(invariants, :must_contain, []) do
      assert out =~ substr,
             """
             #{fixture}: transpile output is missing required substring #{inspect(substr)}.
             Output:
             #{out}
             """
    end

    if max = invariants[:max_lines] do
      lines = out |> String.split("\n") |> length()

      assert lines <= max,
             """
             #{fixture}: transpile output is #{lines} lines, ceiling is #{max}.
             Output likely re-inflated; check whether a helper that previously
             tree-shook is now being pulled in.
             """
    end

    if expected = invariants[:stdout] do
      {_, _value, actual, _diagnostics} = TranspileHelpers.run_source(out)

      assert actual == expected,
             """
             #{fixture}: stdout from running the transpiled program differs.
             Expected: #{inspect(expected)}
             Actual:   #{inspect(actual)}
             """
    end
  end
end
