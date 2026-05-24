defmodule Eval.ReportTest do
  use ExUnit.Case, async: true

  alias Eval.Report

  @tag :tmp_dir
  test "writes summary.md, summary.json, and per-bucket failure files", %{tmp_dir: tmp} do
    acc = %{
      counts: %{
        :ok => 3,
        {:unsupported, "ClassDef"} => 2,
        :parse_error => 1
      },
      samples: %{
        :ok => [%{id: "1", source: "x = 1", metadata: %{}}],
        {:unsupported, "ClassDef"} => [
          %{id: "a", source: "class Foo: pass", metadata: %{node_type: "ClassDef"}},
          %{id: "b", source: "class Bar: pass", metadata: %{node_type: "ClassDef"}}
        ],
        :parse_error => [
          %{id: "p1", source: "def ", metadata: %{message: "invalid syntax"}}
        ]
      },
      totals: %{
        processed: 6,
        transpiled: 3,
        testcases_run: 30,
        testcases_passed: 18
      }
    }

    run_dir = Report.write(acc, out: Path.join(tmp, "run-test"))

    assert File.exists?(Path.join(run_dir, "summary.md"))
    assert File.exists?(Path.join(run_dir, "summary.json"))

    md = File.read!(Path.join(run_dir, "summary.md"))
    assert md =~ "processed | 6"
    assert md =~ "behavioral equivalence | 3"
    assert md =~ "unsupported--ClassDef"
    assert md =~ "testcases run | 30"
    assert md =~ "testcases passed | 18"
    refute md =~ "python preflight"
    refute md =~ "comparison mode"

    json = Path.join(run_dir, "summary.json") |> File.read!() |> Jason.decode!()
    assert json["schema_version"] == 4
    refute Map.has_key?(json, "comparison_mode")
    assert json["totals"]["processed"] == 6
    assert json["totals"]["equivalent"] == 3
    assert json["totals"]["testcases_run"] == 30
    assert json["totals"]["testcases_passed"] == 18
    assert Map.has_key?(json["counts"], "unsupported--ClassDef")

    # Failure samples written; :ok bucket is NOT written.
    assert File.exists?(Path.join([run_dir, "failures", "unsupported--ClassDef", "001.py"]))
    assert File.exists?(Path.join([run_dir, "failures", "unsupported--ClassDef", "002.py"]))
    refute File.exists?(Path.join([run_dir, "failures", "ok"]))

    sample_content =
      Path.join([run_dir, "failures", "unsupported--ClassDef", "001.py"])
      |> File.read!()

    assert sample_content =~ "class Foo: pass"
    assert sample_content =~ "ClassDef"
  end

  @tag :tmp_dir
  test "writes per-testcase artifacts for {:output_mismatch, _} (no python.txt)", %{tmp_dir: tmp} do
    per_tc = [
      {:ok, %{stdin: "1\n", expected: "1", elixir_stdout: "1\n"}},
      {:output_mismatch, "abc",
       %{
         stdin: "2\n",
         expected: "2",
         elixir_stdout: "BAD\n",
         diff_summary: "expected: 1 lines\nactual: 1 lines"
       }}
    ]

    acc = %{
      counts: %{{:output_mismatch, "abc"} => 1},
      samples: %{
        {:output_mismatch, "abc"} => [
          %{
            id: "qid--abcd1234",
            source: "print(input())",
            metadata: %{elixir_source: "defmodule X do def py_main end", per_testcase: per_tc}
          }
        ]
      },
      totals: %{processed: 1, transpiled: 0, testcases_run: 2, testcases_passed: 1}
    }

    run_dir = Report.write(acc, out: Path.join(tmp, "run-mismatch"))

    dir = Path.join([run_dir, "mismatches", "abc"])
    assert File.exists?(Path.join(dir, "001.py"))
    assert File.exists?(Path.join(dir, "001.ex"))
    assert File.exists?(Path.join(dir, "001.summary.md"))

    # Only the *failing* testcase's artifacts get written (idx 1).
    refute File.exists?(Path.join(dir, "001.testcase_0.stdin.txt"))
    assert File.exists?(Path.join(dir, "001.testcase_1.stdin.txt"))
    assert File.exists?(Path.join(dir, "001.testcase_1.expected.txt"))
    assert File.exists?(Path.join(dir, "001.testcase_1.elixir.txt"))
    assert File.exists?(Path.join(dir, "001.testcase_1.diff"))
    # Python output is no longer captured.
    refute File.exists?(Path.join(dir, "001.testcase_1.python.txt"))

    summary = File.read!(Path.join(dir, "001.summary.md"))
    assert summary =~ "qid--abcd1234"
    assert summary =~ "1/2 passed"
    assert summary =~ ":ok"
    assert summary =~ ":output_mismatch"
  end

  @tag :tmp_dir
  test "omits elixir.txt when Elixir didn't produce output", %{tmp_dir: tmp} do
    per_tc = [
      {:output_mismatch, "fp",
       %{stdin: "in\n", expected: "out", elixir_stdout: nil, diff_summary: "diff"}}
    ]

    acc = %{
      counts: %{{:output_mismatch, "fp"} => 1},
      samples: %{
        {:output_mismatch, "fp"} => [
          %{
            id: "qid--abcdef00",
            source: "src",
            metadata: %{elixir_source: "ex_src", per_testcase: per_tc}
          }
        ]
      },
      totals: %{processed: 1, transpiled: 0, testcases_run: 1, testcases_passed: 0}
    }

    run_dir = Report.write(acc, out: Path.join(tmp, "run-noex"))

    dir = Path.join([run_dir, "mismatches", "fp"])
    assert File.exists?(Path.join(dir, "001.testcase_0.stdin.txt"))
    assert File.exists?(Path.join(dir, "001.testcase_0.expected.txt"))
    refute File.exists?(Path.join(dir, "001.testcase_0.elixir.txt"))
  end
end
