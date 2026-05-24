defmodule Dataset.E2ETest do
  @moduledoc """
  T14 — end-to-end smoke + contract. Drives the whole pipeline on a small
  fake slice **under the real sandbox** (exercises the fail-closed
  self-test + netns), then re-runs every shipped row in a fresh process
  and asserts `normalize(stdout) == stored canonical`.
  """
  use ExUnit.Case, async: false
  require Explorer.DataFrame, as: DF

  alias Dataset.{Execute, Normalize}

  # seed_1 & seed_3 are near-duplicates (3 shared, agreeing testcases) →
  # must merge into one task. seed_2 is distinct. Solutions are
  # deterministic; seed_1/seed_3 use equivalent-but-different code.
  defmodule Fake do
    require Explorer.DataFrame, as: DF

    def shard_count(:seed_sft), do: 1
    def shard_count(:seed_testcase), do: 1
    def shard_path(c, i), do: "/nonexistent/#{c}-#{i}.parquet"

    def read_sft_shard(0, _cols) do
      DF.new(
        question_id: ["seed_1", "seed_3", "seed_2"],
        code: [
          "print(int(input()) + 1)",
          "n = int(input())\nprint(n + 1)",
          ~s|print("ok")|
        ],
        is_passed: [true, true, true]
      )
    end

    def read_testcase_shard(0, qids, _cols) do
      shared_in = Jason.encode!(["1\n", "2\n", "3\n"])
      shared_out = Jason.encode!(["2\n", "3\n", "4\n"])

      rows = [
        {"seed_1", shared_in, shared_out},
        {"seed_3", shared_in, shared_out},
        {"seed_2", Jason.encode!([""]), Jason.encode!(["ok\n"])}
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

  setup do
    # Use the real default sandbox (delete any override left by other tests).
    prev = System.get_env("PYLIXIR_DATASET_SANDBOX")
    System.delete_env("PYLIXIR_DATASET_SANDBOX")
    on_exit(fn -> if prev, do: System.put_env("PYLIXIR_DATASET_SANDBOX", prev) end)
    :ok
  end

  test "full build under sandbox merges near-dups, ships verified rows, contract holds" do
    out = Path.join(System.tmp_dir!(), "e2e_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(out) end)

    {:ok, ^out, summary} =
      Dataset.Build.run(
        dataset_module: Fake,
        out_dir: out,
        cache_path: Path.join(out, "cache.jsonl"),
        run_count: 3,
        timeout_ms: 8000
      )

    # seed_1+seed_3 merged → 2 tasks total, both ship.
    assert summary == %{groups: 2, kept: 2, dropped: 0}

    df = DF.from_parquet!(Path.join(out, "data.parquet"))
    ids = DF.pull(df, "id") |> Explorer.Series.to_list()

    # merged task id uses the min member qid
    merged_id = Enum.find(ids, &String.starts_with?(&1, "seed_1--"))
    assert merged_id

    rows = parquet_rows(df)
    merged = Enum.find(rows, &(&1.id == merged_id))
    assert merged.meta["member_qids"] == ["seed_1", "seed_3"]
    assert length(merged.testcases) == 3

    # Contract: re-run every shipped (source, stdin) fresh; the normalized
    # stdout must equal the stored canonical expected.
    for row <- rows, tc <- row.testcases do
      assert {:ok, out_bytes} =
               Execute.run_python(row.source, stdin: tc["stdin"], timeout_ms: 8000)

      assert Normalize.normalize(out_bytes) == tc["expected"],
             "contract violation for #{row.id} on stdin #{inspect(tc["stdin"])}"
    end
  end

  defp parquet_rows(df) do
    ids = DF.pull(df, "id") |> Explorer.Series.to_list()
    sources = DF.pull(df, "source") |> Explorer.Series.to_list()
    tcs = DF.pull(df, "testcases") |> Explorer.Series.to_list() |> Enum.map(&Jason.decode!/1)
    metas = DF.pull(df, "meta") |> Explorer.Series.to_list() |> Enum.map(&Jason.decode!/1)

    [ids, sources, tcs, metas]
    |> Enum.zip()
    |> Enum.map(fn {id, source, testcases, meta} ->
      %{id: id, source: source, testcases: testcases, meta: meta}
    end)
  end
end
