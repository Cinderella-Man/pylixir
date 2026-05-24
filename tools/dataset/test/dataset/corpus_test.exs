defmodule Dataset.CorpusTest do
  use ExUnit.Case, async: true
  require Explorer.DataFrame, as: DF

  alias Dataset.Corpus

  # Fake dataset module implementing the surface `Corpus` injects via
  # `:dataset_module`. One sft shard, one testcase shard.
  defmodule FakeDataset do
    require Explorer.DataFrame, as: DF

    def shard_count(:seed_sft), do: 1
    def shard_count(:seed_testcase), do: 1

    # Non-existent paths → mtime nil → cache always treated cold/invalid.
    def shard_path(config, idx), do: "/nonexistent/#{config}-#{idx}.parquet"

    def read_sft_shard(0, _cols) do
      DF.new(
        question_id: ["seed_1", "seed_1", "seed_1", "seed_2", "seed_3"],
        # seed_1: passed dup ("print(1)") → sha-deduped to 1; failing row dropped
        code: ["print(1)", "print(1)", "print(0)", "print(2)", "print(3)"],
        is_passed: [true, true, false, true, true]
      )
    end

    def read_testcase_shard(0, qid_filter, _cols) do
      rows = [
        {"seed_1", Jason.encode!(["1\n", "2\n"]), Jason.encode!(["one\n", "two\n"])},
        {"seed_3", Jason.encode!(["3\n"]), Jason.encode!(["three\n"])},
        # function-call-style (non-string entries) → dropped by parse
        {"seed_3", Jason.encode!([[1, 2]]), Jason.encode!([[3]])},
        # qid with no solution — excluded by the pushdown filter
        {"seed_99", Jason.encode!(["x\n"]), Jason.encode!(["y\n"])}
      ]

      filter = MapSet.new(qid_filter)
      rows = Enum.filter(rows, fn {qid, _, _} -> MapSet.member?(filter, qid) end)

      DF.new(
        question_id: Enum.map(rows, &elem(&1, 0)),
        inputs: Enum.map(rows, &elem(&1, 1)),
        outputs: Enum.map(rows, &elem(&1, 2))
      )
    end
  end

  defp opts, do: [dataset_module: FakeDataset]

  test "grouped: is_passed filter + sha dedup on solutions" do
    {solutions, _testcases, _stats} = Corpus.grouped(opts())

    assert Map.keys(solutions) |> Enum.sort() == ["seed_1", "seed_2", "seed_3"]
    # seed_1: duplicate passed code deduped, failing row dropped → 1 solution
    assert [%{source: "print(1)"}] = solutions["seed_1"]
    assert length(solutions["seed_2"]) == 1
  end

  test "grouped: testcase JSON parse, function-call rows skipped, pushdown filter" do
    {_solutions, testcases, _stats} = Corpus.grouped(opts())

    assert Map.keys(testcases) |> Enum.sort() == ["seed_1", "seed_3"]
    assert testcases["seed_1"] == [%{stdin: "1\n", expected: "one\n"}, %{stdin: "2\n", expected: "two\n"}]
    # seed_3's function-call-style row dropped → only the string testcase remains
    assert testcases["seed_3"] == [%{stdin: "3\n", expected: "three\n"}]
    # seed_99 had no solution → filtered out by the qid pushdown
    refute Map.has_key?(testcases, "seed_99")
  end

  test "grouped: stats" do
    {_solutions, _testcases, stats} = Corpus.grouped(opts())

    assert stats.total_qids_with_solutions == 3
    assert stats.total_qids_with_testcases == 2
    assert stats.total_solutions == 3
    # seed_2 has a solution but no testcases → 1 orphaned solution
    assert stats.testcase_shard_missing == 1
  end

  test "build: per-(qid,solution) stream only for qids that have testcases" do
    {stream, _stats} = Corpus.build(opts())
    samples = Enum.to_list(stream)

    ids = Enum.map(samples, & &1.id) |> Enum.sort()
    # seed_2 absent (no testcases); ids are "<qid>--<sha8>"
    assert length(samples) == 2
    assert Enum.all?(ids, &(&1 =~ ~r/^seed_[13]--[0-9a-f]{8}$/))

    s1 = Enum.find(samples, &(&1.source == "print(1)"))
    assert length(s1.testcases) == 2
  end
end
