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
      totals: %{processed: 6, skipped: 0, transpiled: 3}
    }

    run_dir =
      Report.write(acc, out: Path.join(tmp, "run-test"), comparison_mode: :compile_only)

    assert File.exists?(Path.join(run_dir, "summary.md"))
    assert File.exists?(Path.join(run_dir, "summary.json"))

    md = File.read!(Path.join(run_dir, "summary.md"))
    assert md =~ "processed | 6"
    assert md =~ "Compile-success | 3"
    assert md =~ "unsupported--ClassDef"
    assert md =~ "comparison mode | `compile_only`"

    json = Path.join(run_dir, "summary.json") |> File.read!() |> Jason.decode!()
    assert json["schema_version"] == 2
    assert json["comparison_mode"] == "compile_only"
    assert json["totals"]["processed"] == 6
    assert json["totals"]["equivalent"] == 3
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
end
