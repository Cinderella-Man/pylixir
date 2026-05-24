defmodule Dataset.BuildTest do
  # Real python, sandbox off, named cache + env mutation → async: false.
  use ExUnit.Case, async: false
  require Explorer.DataFrame, as: DF

  # Two unrelated tasks with trivial, deterministic solutions.
  defmodule Fake do
    require Explorer.DataFrame, as: DF

    def shard_count(:seed_sft), do: 1
    def shard_count(:seed_testcase), do: 1
    def shard_path(c, i), do: "/nonexistent/#{c}-#{i}.parquet"

    def read_sft_shard(0, _cols) do
      DF.new(
        question_id: ["seed_1", "seed_2"],
        code: ["print(int(input()) * 2)", ~s|print("hello")|],
        is_passed: [true, true]
      )
    end

    def read_testcase_shard(0, qids, _cols) do
      rows = [
        {"seed_1", Jason.encode!(["5\n"]), Jason.encode!(["10\n"])},
        {"seed_2", Jason.encode!([""]), Jason.encode!(["hello\n"])}
      ]

      filter = MapSet.new(qids)
      rows = Enum.filter(rows, fn {q, _, _} -> MapSet.member?(filter, q) end)

      DF.new(
        question_id: Enum.map(rows, &elem(&1, 0)),
        inputs: Enum.map(rows, &elem(&1, 1)),
        outputs: Enum.map(rows, &elem(&1, 2))
      )
    end
  end

  defp tmp(suffix) do
    p = Path.join(System.tmp_dir!(), "build_#{System.unique_integer([:positive])}_#{suffix}")
    on_exit(fn -> File.rm_rf(p) end)
    p
  end

  defp base_opts(out) do
    [
      dataset_module: Fake,
      no_sandbox: true,
      out_dir: out,
      cache_path: Path.join(out, "cache.jsonl"),
      run_count: 3,
      timeout_ms: 5000
    ]
  end

  test "full build curates both tasks and writes a readable parquet" do
    out = tmp("full")
    {:ok, ^out, summary} = Dataset.Build.run(base_opts(out))

    assert summary == %{groups: 2, kept: 2, dropped: 0}

    df = DF.from_parquet!(Path.join(out, "data.parquet"))
    assert DF.n_rows(df) == 2

    rows =
      df
      |> DF.pull("testcases")
      |> Explorer.Series.to_list()
      |> Enum.map(&Jason.decode!/1)

    expecteds = rows |> List.flatten() |> Enum.map(& &1["expected"]) |> Enum.sort()
    assert expecteds == ["10", "hello"]
  end

  test "a tiny behavioral load budget still curates correctly (forces per-chunk row loads)" do
    out = tmp("budget")
    {:ok, _, summary} = Dataset.Build.run(base_opts(out) ++ [behavioral_load_budget: 1])
    assert summary == %{groups: 2, kept: 2, dropped: 0}
  end

  test "--limit slices the group list" do
    out = tmp("limit")
    {:ok, _, summary} = Dataset.Build.run(base_opts(out) ++ [limit: 1])
    assert summary.groups == 1
    assert summary.kept == 1
  end

  test "complementary qid-shards partition the groups" do
    out0 = tmp("s0")
    out1 = tmp("s1")
    {:ok, _, s0} = Dataset.Build.run(base_opts(out0) ++ [qid_shard: {0, 2}])
    {:ok, _, s1} = Dataset.Build.run(base_opts(out1) ++ [qid_shard: {1, 2}])

    assert s0.groups + s1.groups == 2
  end
end
