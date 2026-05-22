defmodule Dataset.DatasetTest do
  use ExUnit.Case, async: false
  require Explorer.DataFrame, as: DF

  alias Dataset.Dataset, as: D

  test "shard counts and source repo" do
    assert D.shard_count(:seed_sft) == 20
    assert D.shard_count(:seed_testcase) == 30
    assert D.source_repo() == "microsoft/rStar-Coder"
  end

  test "shard_path uses the zero-padded HF naming convention" do
    assert D.shard_path(:seed_sft, 0) |> Path.basename() == "data-00000-of-00020.parquet"
    assert D.shard_path(:seed_testcase, 3) |> Path.basename() == "data-00003-of-00030.parquet"
  end

  test "download_shard rejects an out-of-range index" do
    assert_raise ArgumentError, fn -> D.download_shard(:seed_sft, 20) end
    assert_raise ArgumentError, fn -> D.download_shard(:seed_sft, -1) end
  end

  test "read_sft_shard reads a present (fixture) shard with column projection" do
    path = D.shard_path(:seed_sft, 0)
    File.mkdir_p!(Path.dirname(path))

    fixture =
      DF.new(
        question_id: ["seed_1", "seed_2"],
        code: ["print(1)", "print(2)"],
        is_passed: [true, false],
        question: ["q one", "q two"]
      )

    DF.to_parquet!(fixture, path)

    on_exit(fn -> File.rm(path) end)

    df = D.read_sft_shard(0, ["question_id", "code", "is_passed"])

    assert DF.names(df) == ["question_id", "code", "is_passed"]
    assert DF.pull(df, "question_id") |> Explorer.Series.to_list() == ["seed_1", "seed_2"]
    assert DF.pull(df, "is_passed") |> Explorer.Series.to_list() == [true, false]
  end
end
