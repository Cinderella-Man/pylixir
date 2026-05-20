defmodule Eval.CorpusTest do
  use ExUnit.Case, async: false

  alias Eval.Corpus
  require Explorer.DataFrame, as: DF

  # FakeDataset implements the same surface as `Eval.Dataset` but reads
  # from a process-dictionary-resident config rather than parquet
  # shards. Each test calls `set_fake/1` to install its frames, then
  # `Corpus.build(dataset_module: FakeDataset, cache_path: tmp, ...)`.
  defmodule FakeDataset do
    @config_key :__corpus_test_fake_config__

    def set(config), do: Process.put(@config_key, config)
    def get, do: Process.get(@config_key)

    def shard_count(:seed_sft), do: length(get().sft_shards)
    def shard_count(:seed_testcase), do: length(get().tc_shards)

    def shard_path(:seed_sft, idx), do: "/tmp/fake_sft_#{idx}"
    def shard_path(:seed_testcase, idx), do: "/tmp/fake_tc_#{idx}"

    def read_sft_shard(idx, cols) do
      get()
      |> Map.fetch!(:sft_shards)
      |> Enum.at(idx)
      |> DF.select(cols)
    end

    def read_testcase_shard(idx, _qid_filter, cols) do
      # The real Dataset uses Polars filter pushdown by qid; for tests
      # we just return the pre-built shard. Corpus.build only consumes
      # the rows it joins against, so unfiltered fake shards are fine.
      get()
      |> Map.fetch!(:tc_shards)
      |> Enum.at(idx)
      |> DF.select(cols)
    end
  end

  setup do
    tmp_cache =
      Path.join(
        System.tmp_dir!(),
        "corpus_test_#{System.unique_integer([:positive])}.term.gz"
      )

    on_exit(fn ->
      File.rm(tmp_cache)
      File.rm(tmp_cache <> ".partial")
    end)

    {:ok, tmp_cache: tmp_cache}
  end

  test "dedups solutions by (qid, sha256(source))", %{tmp_cache: tmp_cache} do
    FakeDataset.set(%{
      sft_shards: [
        # q1 appears with code "A" twice + "B" once. Dedup → {q1, A}, {q1, B}.
        # q2 appears once. q3 has is_passed=false — must be dropped.
        DF.new(
          question_id: ["q1", "q1", "q1", "q2", "q3"],
          code: ["A", "A", "B", "C", "D"],
          is_passed: [true, true, true, true, false]
        )
      ],
      tc_shards: [
        DF.new(
          question_id: ["q1", "q1", "q2"],
          inputs: ["i1", "i2", "i3"],
          outputs: ["o1", "o2", "o3"]
        )
      ]
    })

    {stream, stats} = build_silent(tmp_cache: tmp_cache)
    samples = Enum.to_list(stream)

    # q3 is dropped (is_passed=false). q1 dedups A,A,B → 2 solutions.
    # q2 has 1 solution. Both q1 and q2 have testcases.
    assert stats.total_solutions == 3
    assert stats.total_qids_with_solutions == 2
    assert stats.total_qids_with_testcases == 2
    assert stats.testcase_shard_missing == 0

    assert length(samples) == 3

    by_qid = Enum.group_by(samples, &qid_of/1)
    assert length(by_qid["q1"]) == 2
    assert length(by_qid["q2"]) == 1

    # Both q1 samples share their full testcase set.
    q1_samples = by_qid["q1"]
    assert Enum.all?(q1_samples, &(length(&1.testcases) == 2))

    # IDs follow the `<qid>--<sha8>` convention.
    Enum.each(samples, fn s ->
      assert String.starts_with?(s.id, qid_of(s) <> "--")
      assert String.length(s.id) - String.length(qid_of(s)) - 2 == 8
    end)
  end

  test "only qids in both solutions and testcases yield samples", %{tmp_cache: tmp_cache} do
    FakeDataset.set(%{
      sft_shards: [
        DF.new(
          question_id: ["q1", "q2", "q3"],
          code: ["A", "B", "C"],
          is_passed: [true, true, true]
        )
      ],
      tc_shards: [
        # q2's testcases live in a (notional) shard NOT loaded. q3 has
        # no testcases anywhere. Only q1 yields samples.
        DF.new(question_id: ["q1"], inputs: ["i"], outputs: ["o"])
      ]
    })

    {stream, stats} = build_silent(tmp_cache: tmp_cache)
    samples = Enum.to_list(stream)

    assert length(samples) == 1
    assert hd(samples).id |> String.starts_with?("q1--")

    # q2 and q3 each have 1 passing solution but no joined testcases.
    assert stats.testcase_shard_missing == 2
    assert stats.total_solutions == 3
    assert stats.total_qids_with_solutions == 3
    assert stats.total_qids_with_testcases == 1
  end

  test "loads K testcase shards", %{tmp_cache: tmp_cache} do
    FakeDataset.set(%{
      sft_shards: [
        DF.new(
          question_id: ["q1", "q2"],
          code: ["A", "B"],
          is_passed: [true, true]
        )
      ],
      tc_shards: [
        DF.new(question_id: ["q1"], inputs: ["i1"], outputs: ["o1"]),
        DF.new(question_id: ["q2"], inputs: ["i2"], outputs: ["o2"])
      ]
    })

    {stream_k1, stats_k1} = build_silent(tmp_cache: tmp_cache, testcase_shards: 1)
    assert stats_k1.testcase_shard_missing == 1
    assert length(Enum.to_list(stream_k1)) == 1

    # Different tmp cache so the K=1 cache doesn't shadow this K=2 build.
    tmp_cache_2 = tmp_cache <> ".k2"
    on_exit(fn -> File.rm(tmp_cache_2) end)

    {stream_k2, stats_k2} = build_silent(tmp_cache: tmp_cache_2, testcase_shards: 2)
    assert stats_k2.testcase_shard_missing == 0
    assert length(Enum.to_list(stream_k2)) == 2
  end

  test "yielded samples carry testcases as a list of %{stdin, expected}",
       %{tmp_cache: tmp_cache} do
    FakeDataset.set(%{
      sft_shards: [
        DF.new(question_id: ["q1"], code: ["src"], is_passed: [true])
      ],
      tc_shards: [
        DF.new(
          question_id: ["q1", "q1"],
          inputs: ["i1", "i2"],
          outputs: ["o1", "o2"]
        )
      ]
    })

    {stream, _stats} = build_silent(tmp_cache: tmp_cache)
    [sample] = Enum.to_list(stream)

    assert sample.source == "src"
    assert is_list(sample.testcases)
    assert length(sample.testcases) == 2

    Enum.each(sample.testcases, fn tc ->
      assert Map.has_key?(tc, :stdin)
      assert Map.has_key?(tc, :expected)
    end)
  end

  defp build_silent(extra_opts) do
    opts =
      Keyword.merge(
        [dataset_module: FakeDataset],
        extra_opts
      )
      |> Keyword.put_new(:testcase_shards, 1)
      |> rename_key(:tmp_cache, :cache_path)

    {result, _io} = ExUnit.CaptureIO.with_io(fn -> Corpus.build(opts) end)
    result
  end

  defp rename_key(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {val, opts} -> Keyword.put(opts, to, val)
    end
  end

  defp qid_of(%{id: id}) do
    [qid, _sha8] = String.split(id, "--", parts: 2)
    qid
  end
end
