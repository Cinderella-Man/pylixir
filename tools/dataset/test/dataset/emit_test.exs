defmodule Dataset.EmitTest do
  use ExUnit.Case, async: true
  require Explorer.DataFrame, as: DF

  alias Dataset.Emit

  defp result do
    %{
      id: "seed_1--abc12345",
      source: "print(input())",
      solution_sha256: "abc12345deadbeef",
      testcases: [
        %{stdin: "hi\r\n", expected: "hi", n_stored_outputs: 2},
        %{stdin: "yo\n", expected: "yo", n_stored_outputs: 1}
      ],
      member_qids: ["seed_1", "seed_9"],
      alternate_solution_shas: ["ffff0000"]
    }
  end

  defp out_dir do
    dir = Path.join(System.tmp_dir!(), "emit_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "round-trip: parquet re-reads with the right schema and canonical content" do
    dir = out_dir()
    {:ok, ^dir} = Emit.emit([result()], out_dir: dir, version: "vtest")

    df = DF.from_parquet!(Path.join(dir, "data.parquet"))

    assert DF.names(df) ==
             ["id", "source", "solution_sha256", "testcases", "num_testcases", "meta"]

    assert DF.pull(df, "id") |> Explorer.Series.to_list() == ["seed_1--abc12345"]
    assert DF.pull(df, "num_testcases") |> Explorer.Series.to_list() == [2]

    # testcases column is a JSON string; parse and check byte-exact stdin +
    # normalized expected + n_stored_outputs
    [tc_json] = DF.pull(df, "testcases") |> Explorer.Series.to_list()
    tcs = Jason.decode!(tc_json)

    assert tcs == [
             %{"stdin" => "hi\r\n", "expected" => "hi", "n_stored_outputs" => 2},
             %{"stdin" => "yo\n", "expected" => "yo", "n_stored_outputs" => 1}
           ]

    [meta_json] = DF.pull(df, "meta") |> Explorer.Series.to_list()
    meta = Jason.decode!(meta_json)
    assert meta["member_qids"] == ["seed_1", "seed_9"]
    assert meta["alternate_solution_shas"] == ["ffff0000"]
    assert meta["source_repo"] == "microsoft/rStar-Coder"
  end

  test "jsonl mirror parses to the same logical rows (nested)" do
    dir = out_dir()
    Emit.emit([result()], out_dir: dir)

    [line] = Path.join(dir, "data.jsonl") |> File.read!() |> String.split("\n", trim: true)
    row = Jason.decode!(line)

    assert row["id"] == "seed_1--abc12345"
    assert row["num_testcases"] == 2
    # nested in JSONL (not a string)
    assert is_list(row["testcases"])
    assert hd(row["testcases"])["stdin"] == "hi\r\n"
    assert is_map(row["meta"])
  end

  test "provenance records the reproducibility/merge/filter parameters" do
    dir = out_dir()
    Emit.emit([result()], out_dir: dir, version: "v9", source_revision: "abc123")

    prov = Path.join(dir, "provenance.json") |> File.read!() |> Jason.decode!()

    assert prov["version"] == "v9"
    assert prov["source_revision"] == "abc123"
    assert prov["runs_per_testcase"] == 5
    assert prov["curation_size_filter_bytes"] == 1024 * 1024
    assert prov["testcase_cap"] == 32
    assert prov["num_rows"] == 1
    assert prov["source_repo"] == "microsoft/rStar-Coder"
  end

  test "explicit out_dir: nil falls back to out/<version> instead of crashing" do
    {:ok, dir} = Emit.emit([result()], out_dir: nil, version: "vnil_test")
    on_exit(fn -> File.rm_rf(dir) end)

    assert String.ends_with?(dir, Path.join("out", "vnil_test"))
    assert File.exists?(Path.join(dir, "data.parquet"))
  end

  test "dataset card credits upstream, names CC BY 4.0, states no problem statement" do
    dir = out_dir()
    Emit.emit([result()], out_dir: dir)

    card = Path.join(dir, "dataset_card.md") |> File.read!()
    assert card =~ "CC BY 4.0"
    assert card =~ "microsoft/rStar-Coder"
    assert card =~ "problem statements removed"
  end
end
