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
        testcases_passed: 18,
        testcase_shard_missing: 5
      }
    }

    run_dir = Report.write(acc, out: Path.join(tmp, "run-test"))

    assert File.exists?(Path.join(run_dir, "summary.md"))
    assert File.exists?(Path.join(run_dir, "summary.json"))

    md = File.read!(Path.join(run_dir, "summary.md"))
    assert md =~ "processed | 6"
    assert md =~ "behavioral equivalence | 3"
    assert md =~ "unsupported--ClassDef"
    assert md =~ "comparison mode | `executed`"
    assert md =~ "testcases run | 30"
    assert md =~ "testcases passed | 18"
    assert md =~ "5 passing solutions have testcases in seed_testcase shards not loaded"

    json = Path.join(run_dir, "summary.json") |> File.read!() |> Jason.decode!()
    assert json["schema_version"] == 3
    assert json["comparison_mode"] == "executed"
    assert json["totals"]["processed"] == 6
    assert json["totals"]["equivalent"] == 3
    assert json["totals"]["testcases_run"] == 30
    assert json["totals"]["testcases_passed"] == 18
    assert json["totals"]["testcase_shard_missing"] == 5
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
  test "writes per-testcase artifacts for {:output_mismatch, _}", %{tmp_dir: tmp} do
    per_tc = [
      {:ok, %{stdin: "1\n", expected: "1\n", python_stdout: "1\n", elixir_stdout: "1\n"}},
      {:output_mismatch, "abc",
       %{
         stdin: "2\n",
         expected: "2\n",
         python_stdout: "2\n",
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
      totals: %{
        processed: 1,
        transpiled: 0,
        testcases_run: 2,
        testcases_passed: 1,
        testcase_shard_missing: 0
      }
    }

    run_dir = Report.write(acc, out: Path.join(tmp, "run-mismatch"))

    mismatch_dir = Path.join([run_dir, "mismatches", "abc"])
    assert File.exists?(Path.join(mismatch_dir, "001.py"))
    assert File.exists?(Path.join(mismatch_dir, "001.ex"))
    assert File.exists?(Path.join(mismatch_dir, "001.summary.md"))

    # Only the *failing* testcase's artifacts get written (idx 1).
    refute File.exists?(Path.join(mismatch_dir, "001.testcase_0.stdin.txt"))
    assert File.exists?(Path.join(mismatch_dir, "001.testcase_1.stdin.txt"))
    assert File.exists?(Path.join(mismatch_dir, "001.testcase_1.expected.txt"))
    assert File.exists?(Path.join(mismatch_dir, "001.testcase_1.python.txt"))
    assert File.exists?(Path.join(mismatch_dir, "001.testcase_1.elixir.txt"))
    assert File.exists?(Path.join(mismatch_dir, "001.testcase_1.diff"))

    summary = File.read!(Path.join(mismatch_dir, "001.summary.md"))
    assert summary =~ "qid--abcd1234"
    assert summary =~ "1/2 passed"
    assert summary =~ ":ok"
    assert summary =~ ":output_mismatch"
  end

  @tag :tmp_dir
  test "writes per-testcase artifacts for {:python_disagrees_expected, _}", %{tmp_dir: tmp} do
    per_tc = [
      {:python_disagrees_expected, "py_fp",
       %{
         stdin: "x\n",
         expected: "wrong\n",
         python_stdout: "x\n",
         elixir_stdout: "x\n",
         diff_summary: "py != expected"
       }}
    ]

    acc = %{
      counts: %{{:python_disagrees_expected, "py_fp"} => 1},
      samples: %{
        {:python_disagrees_expected, "py_fp"} => [
          %{
            id: "qid--12345678",
            source: "print(input())",
            metadata: %{elixir_source: "defmodule X do def py_main end", per_testcase: per_tc}
          }
        ]
      },
      totals: %{
        processed: 1,
        transpiled: 0,
        testcases_run: 1,
        testcases_passed: 0,
        testcase_shard_missing: 0
      }
    }

    run_dir = Report.write(acc, out: Path.join(tmp, "run-pde"))

    pde_dir = Path.join([run_dir, "mismatches", "py_fp"])
    assert File.exists?(Path.join(pde_dir, "001.py"))
    assert File.exists?(Path.join(pde_dir, "001.summary.md"))
    assert File.exists?(Path.join(pde_dir, "001.testcase_0.stdin.txt"))
    assert File.exists?(Path.join(pde_dir, "001.testcase_0.expected.txt"))
    assert File.exists?(Path.join(pde_dir, "001.testcase_0.python.txt"))
    assert File.exists?(Path.join(pde_dir, "001.testcase_0.diff"))

    # Elixir actually ran here; elixir.txt should be written too.
    assert File.exists?(Path.join(pde_dir, "001.testcase_0.elixir.txt"))
  end

  @tag :tmp_dir
  test "omits elixir.txt when Elixir didn't run", %{tmp_dir: tmp} do
    per_tc = [
      {:python_failed, :timeout,
       %{stdin: "", expected: "", python_stdout: nil}}
    ]

    # `:python_failed` on every testcase rolls up to a python bucket
    # (e.g. `:python_timeout`), which goes into `failures/`, not
    # `mismatches/`. To exercise the elixir.txt-omission path in
    # `mismatches/`, build an `{:output_mismatch, _}` shell where the
    # failing testcase happens to have `elixir_stdout: nil`.
    per_tc_om = [
      {:output_mismatch, "fp",
       %{
         stdin: "in\n",
         expected: "out\n",
         python_stdout: "py\n",
         elixir_stdout: nil,
         diff_summary: "diff"
       }}
    ]

    acc = %{
      counts: %{{:output_mismatch, "fp"} => 1},
      samples: %{
        {:output_mismatch, "fp"} => [
          %{
            id: "qid--abcdef00",
            source: "src",
            metadata: %{elixir_source: "ex_src", per_testcase: per_tc_om}
          }
        ]
      },
      totals: %{
        processed: 1,
        transpiled: 0,
        testcases_run: 1,
        testcases_passed: 0,
        testcase_shard_missing: 0
      }
    }

    run_dir = Report.write(acc, out: Path.join(tmp, "run-noex"))

    dir = Path.join([run_dir, "mismatches", "fp"])
    assert File.exists?(Path.join(dir, "001.testcase_0.stdin.txt"))
    assert File.exists?(Path.join(dir, "001.testcase_0.python.txt"))
    refute File.exists?(Path.join(dir, "001.testcase_0.elixir.txt"))

    # Sanity: per_tc_om is the only branch read by the report; per_tc is
    # defined for documentation but unused here.
    _ = per_tc
  end
end
