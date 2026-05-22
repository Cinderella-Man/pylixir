defmodule Dataset.Build do
  @moduledoc """
  Orchestrates Stages 0→4 into a dataset. Plain module (the Mix task
  `Mix.Tasks.Dataset.Build` is a thin argv wrapper) so the whole pipeline
  is testable with an injected dataset module. See
  docs/12_dataset-curation-plan.md §Pipeline.

  Flow: `Corpus.grouped` → `MergeGroups.build` (solution qids) →
  `Candidates.build` → shard/skip/limit over merge-groups →
  `Select.select` per group (concurrent) → `Emit.emit`.

  Resumable: the `(source, stdin)` verdict cache (`Dataset.PythonCache`)
  means a restart skips completed verification.
  """

  alias Dataset.{Candidates, Corpus, Emit, MergeGroups, PythonCache, Sandbox, Select}
  require Logger

  @doc """
  Run the build. Returns `{:ok, out_dir, summary}`.

  ## Options
    * `:dataset_module` — default `Dataset.Dataset`.
    * `:testcase_shards` — shards loaded for both text and fingerprints (default 1).
    * `:qid_shard` — `{i, n}` to process only merge-groups where `phash2(group_id, n) == i`.
    * `:skip`, `:limit` — slice the (sorted) group list.
    * `:run_count` (5), `:testcase_cap` (32), `:timeout_ms` (20_000), `:size_limit` (1 MB).
    * `:concurrency` — Select workers (default `schedulers_online`).
    * `:no_sandbox` — skip the self-test and run python unsandboxed (trusted/test only).
    * `:cache_path` — verdict cache JSONL (default `cache/verify.jsonl`).
    * `:version` ("v0"), `:out_dir`, `:source_revision` ("main").
  """
  @spec run(keyword()) :: {:ok, String.t(), map()}
  def run(opts \\ []) do
    dataset = Keyword.get(opts, :dataset_module, Dataset.Dataset)
    k = Keyword.get(opts, :testcase_shards, 1)

    configure_sandbox(opts)
    {:ok, _} = PythonCache.ensure_started(path: cache_path(opts))
    unless Keyword.get(opts, :no_sandbox, false), do: Sandbox.self_test!()

    Logger.info("[build] loading corpus (testcase_shards=#{k})")

    corpus_opts =
      [dataset_module: dataset, testcase_shards: k]
      |> maybe_put(:cache_path, Keyword.get(opts, :corpus_cache_path))

    {solutions_by_qid, testcases_by_qid, stats} = Corpus.grouped(corpus_opts)

    Logger.info("[build] #{stats.total_qids_with_solutions} qids with solutions; grouping near-dups")
    qid_to_group =
      MergeGroups.build(Map.keys(solutions_by_qid),
        dataset_module: dataset,
        testcase_shards: k
      )

    groups =
      Candidates.build(solutions_by_qid, testcases_by_qid, qid_to_group,
        size_limit: Keyword.get(opts, :size_limit, Candidates.size_limit())
      )

    selected =
      groups
      |> Map.values()
      |> Enum.sort_by(& &1.group_id)
      |> apply_shard(Keyword.get(opts, :qid_shard))
      |> apply_skip_limit(Keyword.get(opts, :skip), Keyword.get(opts, :limit))

    total = length(selected)
    Logger.info("[build] selecting over #{total} merge-groups")

    select_opts = [
      run_count: Keyword.get(opts, :run_count, 5),
      timeout_ms: Keyword.get(opts, :timeout_ms, 20_000),
      testcase_cap: Keyword.get(opts, :testcase_cap, 32)
    ]

    counter = :counters.new(1, [:atomics])

    results =
      selected
      |> Task.async_stream(
        fn group -> select_with_progress(group, select_opts, counter, total) end,
        max_concurrency: Keyword.get(opts, :concurrency, System.schedulers_online()),
        timeout: :infinity,
        ordered: true
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, result}} -> [result]
        {:ok, :drop} -> []
      end)
      |> Enum.sort_by(& &1.id)

    {:ok, out_dir} =
      Emit.emit(results,
        version: Keyword.get(opts, :version, "v0"),
        out_dir: Keyword.get(opts, :out_dir),
        source_revision: Keyword.get(opts, :source_revision, "main")
      )

    summary = %{groups: total, kept: length(results), dropped: total - length(results)}
    Logger.info("[build] done: #{summary.kept} kept / #{summary.dropped} dropped → #{out_dir}")
    {:ok, out_dir, summary}
  end

  # --- Internals -------------------------------------------------------

  defp select_with_progress(group, opts, counter, total) do
    result = Select.select(group, opts)
    :counters.add(counter, 1, 1)
    n = :counters.get(counter, 1)
    if rem(n, 25) == 0 or n == total, do: Logger.info("[build] #{n}/#{total} groups")
    result
  end

  defp configure_sandbox(opts) do
    cond do
      Keyword.get(opts, :no_sandbox, false) ->
        System.put_env("PYLIXIR_DATASET_SANDBOX", "")

      Keyword.has_key?(opts, :as_bytes) or Keyword.has_key?(opts, :cpu_seconds) ->
        System.put_env(
          "PYLIXIR_DATASET_SANDBOX",
          Sandbox.default_prefix(Keyword.take(opts, [:as_bytes, :cpu_seconds]))
        )

      true ->
        :ok
    end
  end

  defp cache_path(opts) do
    Keyword.get(opts, :cache_path, Path.expand("../../cache/verify.jsonl", __DIR__))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp apply_shard(groups, nil), do: groups

  defp apply_shard(groups, {i, n}) do
    Enum.filter(groups, fn g -> rem(:erlang.phash2(g.group_id, n), n) == i end)
  end

  defp apply_skip_limit(groups, skip, limit) do
    groups
    |> then(fn g -> if skip, do: Enum.drop(g, skip), else: g end)
    |> then(fn g -> if limit, do: Enum.take(g, limit), else: g end)
  end
end
