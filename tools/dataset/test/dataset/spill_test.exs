defmodule Dataset.SpillTest do
  use ExUnit.Case, async: true
  require Explorer.DataFrame, as: DF

  alias Dataset.Spill

  # A,B share group "A"; C is its own group. Testcases split across 2 shards.
  defmodule Fake do
    require Explorer.DataFrame, as: DF

    def shard_count(:seed_testcase), do: 2

    def read_testcase_shard(0, qids, _cols) do
      rows = [
        {"A", Jason.encode!(["a1\n"]), Jason.encode!(["x\n"])},
        {"B", Jason.encode!(["b1\n"]), Jason.encode!(["y\n"])},
        {"C", Jason.encode!(["c1\n"]), Jason.encode!(["z\n"])}
      ]

      frame(rows, qids)
    end

    def read_testcase_shard(1, qids, _cols) do
      big = String.duplicate("X", 50)

      rows = [
        # A's second testcase, in a different shard → must land in A's bucket
        {"A", Jason.encode!(["a2\n"]), Jason.encode!(["x2\n"])},
        # oversized → dropped by the size filter
        {"A", Jason.encode!([big <> "\n"]), Jason.encode!(["huge\n"])}
      ]

      frame(rows, qids)
    end

    defp frame(rows, qids) do
      filter = MapSet.new(qids)
      rows = Enum.filter(rows, fn {q, _, _} -> MapSet.member?(filter, q) end)

      DF.new(
        question_id: Enum.map(rows, &elem(&1, 0)),
        inputs: Enum.map(rows, &elem(&1, 1)),
        outputs: Enum.map(rows, &elem(&1, 2))
      )
    end
  end

  defp qid_to_group, do: %{"A" => "A", "B" => "A", "C" => "C"}

  defp read_all(dir, buckets) do
    Enum.reduce(0..(buckets - 1), %{}, fn b, acc ->
      Map.merge(acc, Spill.read_bucket(dir, b), fn _q, l, r -> l ++ r end)
    end)
  end

  test "spills + reads back testcases grouped by qid, across shards, size-filtered" do
    selected = MapSet.new(["A", "C"])
    {dir, buckets} = Spill.run(qid_to_group(), selected, dataset_module: Fake, size_limit: 10)
    on_exit(fn -> Spill.cleanup(dir) end)

    all = read_all(dir, buckets)

    # A has both shards' testcases; the oversized one was dropped
    a_stdins = all["A"] |> Enum.map(& &1.stdin) |> Enum.sort()
    assert a_stdins == ["a1\n", "a2\n"]
    assert all["B"] |> Enum.map(& &1.stdin) == ["b1\n"]
    assert all["C"] |> Enum.map(& &1.stdin) == ["c1\n"]
  end

  test "a group's qids land in the same bucket (route by group, not qid)" do
    selected = MapSet.new(["A", "C"])
    {dir, buckets} = Spill.run(qid_to_group(), selected, dataset_module: Fake)
    on_exit(fn -> Spill.cleanup(dir) end)

    # find the bucket holding A; it must also hold B (same group "A")
    bucket_maps = for b <- 0..(buckets - 1), do: Spill.read_bucket(dir, b)
    a_bucket = Enum.find(bucket_maps, &Map.has_key?(&1, "A"))

    assert Map.has_key?(a_bucket, "B")
  end

  test "testcases of unselected groups are not spilled" do
    selected = MapSet.new(["A"])
    {dir, buckets} = Spill.run(qid_to_group(), selected, dataset_module: Fake)
    on_exit(fn -> Spill.cleanup(dir) end)

    all = read_all(dir, buckets)
    assert Map.has_key?(all, "A")
    refute Map.has_key?(all, "C")
  end
end
