defmodule Dataset.Build do
  @moduledoc """
  Orchestrates Stages 0→4 into a dataset. Plain module (the Mix task
  `Mix.Tasks.Dataset.Build` is a thin argv wrapper) so the whole pipeline
  is testable with an injected dataset module. See
  docs/12_dataset-curation-plan.md §Pipeline.

  Two-pass flow so the **whole dataset** is processed by default while
  memory stays bounded by the slice you're building:

    1. `Corpus.solutions` — all `seed_sft` shards (code is small).
    2. `MergeGroups.build` — fingerprint **all** `seed_testcase` shards
       (hashes only) → `qid → group`.
    3. pick the `--qid-shard`/`--skip`/`--limit` slice of merge-groups.
    4. `Corpus.testcases` — load testcases for **only the slice's qids**
       (across all shards) → bounded resident memory.
    5. `Candidates.build` → `Select.select` per group (concurrent),
       spilling chosen rows to disk while keeping only `Dataset.Dedup`
       fingerprints resident.
    6. `Dedup.cluster` over the fingerprints (a stricter, fanout-cap-free
       pass on the shipped rows) → re-read survivors from disk → `Emit`.

  With no slicing options the slice is the entire corpus. `--qid-shard
  i/N` is the lever to split a run across processes/machines (and to cap
  the resident testcase set). Resumable via the `(source, stdin)` verdict
  cache (`Dataset.PythonCache`).
  """

  alias Dataset.{Behavioral, Candidates, Corpus, Dedup, Emit, MergeGroups, PythonCache, Sandbox, Select, SourceNorm, Spill}
  require Logger

  @doc """
  Run the build. Returns `{:ok, out_dir, summary}`.

  ## Options
    * `:dataset_module` — default `Dataset.Dataset`.
    * `:qid_shard` — `{i, n}` to process only merge-groups where `phash2(group_id, n) == i`.
    * `:skip`, `:limit` — slice the (sorted) group list.
    * `:run_count` (5), `:testcase_cap` (32), `:timeout_ms` (20_000), `:size_limit` (1 MB).
    * `:dedup_min_shared` — global post-selection dedup threshold (default 2; 0 disables). See `Dataset.Dedup`.
    * `:sim_threshold` — source-similarity (Jaro) cutoff for merging producer-multiplied
      near-dups (default 0.8; 0 disables). Pure Elixir, no code execution. See `Dataset.Dedup.similar_edges/3`.
    * `:behavioral` — behavioral-equivalence dedup (default `true`; runs python on
      candidate pairs, resumable via the verdict cache). See `Dataset.Behavioral`.
    * `:concurrency` — Select workers (default `schedulers_online`).
    * `:no_sandbox` — skip the self-test and run python unsandboxed (trusted/test only).
    * `:cache_path` — verdict cache JSONL (default `cache/verify.jsonl`).
    * `:version` ("v0"), `:out_dir`, `:source_revision` ("main").
  """
  @spec run(keyword()) :: {:ok, String.t(), map()}
  def run(opts \\ []) do
    dataset = Keyword.get(opts, :dataset_module, Dataset.Dataset)
    size_limit = Keyword.get(opts, :size_limit, Candidates.size_limit())

    configure_sandbox(opts)
    {:ok, _} = PythonCache.ensure_started(path: cache_path(opts))
    unless Keyword.get(opts, :no_sandbox, false), do: Sandbox.self_test!()

    Logger.info("[build] loading solutions")
    solutions_by_qid = Corpus.solutions(dataset_module: dataset)

    Logger.info("[build] #{map_size(solutions_by_qid)} qids with solutions; fingerprinting near-dups")
    qid_to_group = MergeGroups.build(Map.keys(solutions_by_qid), dataset_module: dataset)

    # group_id => [member qids]
    members_by_group =
      Enum.reduce(qid_to_group, %{}, fn {qid, gid}, acc ->
        Map.update(acc, gid, [qid], &[qid | &1])
      end)

    selected_gids =
      members_by_group
      |> Map.keys()
      |> Enum.sort()
      |> apply_shard(Keyword.get(opts, :qid_shard))
      |> apply_skip_limit(Keyword.get(opts, :skip), Keyword.get(opts, :limit))
      |> MapSet.new()

    total = MapSet.size(selected_gids)
    Logger.info("[build] spilling testcases for #{total} merge-groups to disk")

    {spill_dir, buckets} =
      Spill.run(qid_to_group, selected_gids,
        dataset_module: dataset,
        size_limit: size_limit
      )

    select_opts =
      [
        run_count: Keyword.get(opts, :run_count, 5),
        timeout_ms: Keyword.get(opts, :timeout_ms, 20_000),
        testcase_cap: Keyword.get(opts, :testcase_cap, 32)
      ]
      |> then(fn o ->
        case Keyword.get(opts, :solution_cap) do
          nil -> o
          cap -> Keyword.put(o, :solution_cap, cap)
        end
      end)

    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())
    counter = :counters.new(1, [:atomics])

    Logger.info("[build] selecting over #{buckets} buckets")

    emit_opts = [
      version: Keyword.get(opts, :version, "v0"),
      out_dir: Keyword.get(opts, :out_dir),
      source_revision: Keyword.get(opts, :source_revision, "main"),
      provenance: %{"post_selection_dedup" => dedup_provenance(opts)}
    ]

    # Stage A — select, spilling full rows to disk while keeping only
    # lightweight fingerprints (hashes) resident. Never buffer the whole
    # dataset (the OOM at full scale; see Dataset.Emit/Dataset.Dedup).
    results_path = Path.join(System.tmp_dir!(), "dataset_results_#{System.unique_integer([:positive])}.bin")
    {:ok, wh} = :file.open(results_path, [:write, :binary, :raw])

    {fingerprints, sources} =
      try do
        Enum.reduce(0..(buckets - 1), {[], []}, fn b, acc ->
          # Sort each bucket by id so the on-disk row order is deterministic
          # (buckets are written in index order); survivors keep that order.
          spill_dir
          |> process_bucket(b, solutions_by_qid, qid_to_group, size_limit, select_opts, concurrency, counter, total)
          |> Enum.sort_by(& &1.id)
          |> Enum.reduce(acc, fn result, {fps, srcs} ->
            write_result(wh, result)
            {[Dedup.fingerprint(result) | fps], [{result.id, result.source} | srcs]}
          end)
        end)
      after
        :file.close(wh)
        Spill.cleanup(spill_dir)
      end

    # Stage B — global dedup over fingerprints only (payloads stay on disk).
    # Canonical-source hashing (optional Python AST step) adds the source
    # signal that catches comment/whitespace/rename-only duplicates;
    # behavioral equivalence (optional, runs python) adds the rest.
    norm_hashes = source_norm(sources, opts)
    sim_edges = source_sim(fingerprints, norm_hashes, sources, opts)
    behavioral_edges = behavioral(fingerprints, norm_hashes, results_path, opts)
    {keep, overrides} = dedup(fingerprints, norm_hashes, sim_edges ++ behavioral_edges, opts)

    # Stage C — re-read survivors from disk, fold merge meta, stream to emit.
    {:ok, out_dir, kept} =
      Emit.with_writer(emit_opts, fn writer ->
        try do
          results_path
          |> stream_results()
          |> Stream.filter(fn r -> keep == nil or MapSet.member?(keep, r.id) end)
          |> Stream.map(fn r -> apply_override(r, overrides) end)
          |> Stream.chunk_every(500)
          |> Enum.each(fn chunk -> Emit.write(writer, chunk) end)
        after
          File.rm(results_path)
        end
      end)

    summary = %{groups: total, kept: kept, dropped: total - kept}
    Logger.info("[build] done: #{summary.kept} kept / #{summary.dropped} dropped → #{out_dir}")
    {:ok, out_dir, summary}
  end

  # --- Internals -------------------------------------------------------

  # Global dedup of the selected rows (a stricter pass over the merge
  # stage; see Dataset.Dedup). `:dedup_min_shared` (default 2) is the
  # min shared stdins to union two rows; 0 disables dedup entirely.
  defp dedup(fingerprints, norm_hashes, extra_edges, opts) do
    case Keyword.get(opts, :dedup_min_shared, 2) do
      n when n in [nil, 0] ->
        {nil, %{}}

      min_shared ->
        {keep, overrides} =
          Dedup.cluster(fingerprints,
            min_shared: min_shared,
            norm_hashes: norm_hashes,
            extra_edges: extra_edges
          )

        Logger.info(
          "[dedup] #{length(fingerprints)} rows → #{MapSet.size(keep)} kept " <>
            "(#{map_size(overrides)} clusters merged, min_shared=#{min_shared})"
        )

        {keep, overrides}
    end
  end

  # Records the actual post-selection dedup config used (for provenance).
  defp dedup_provenance(opts) do
    case Keyword.get(opts, :dedup_min_shared, 2) do
      n when n in [nil, 0] ->
        %{"enabled" => false}

      min_shared ->
        sim = Keyword.get(opts, :sim_threshold, 0.8)
        norm = Keyword.get(opts, :source_norm, "struct") |> to_string()

        %{
          "enabled" => true,
          "min_shared_stdins" => min_shared,
          "zero_disagreements" => true,
          "transitive" => true,
          "canonical_source" => if(norm in ["none", "0", ""], do: false, else: norm),
          "source_similarity_jaro" => if(sim > 0, do: sim, else: false),
          "behavioral_equivalence" => behavioral?(opts)
        }
    end
  end

  # Source-similarity edges (pure Elixir, default-on with dedup). Reuses
  # the cheap candidate gate (Dedup.candidates — seed-adjacency + single
  # shared stdin) then keeps pairs whose sources are textually similar
  # (Jaro >= :sim_threshold, default 0.8). Catches producer-multiplied
  # task variations no other signal sees, and runs no code (unlike the
  # behavioral pass), so it cannot OOM. `:sim_threshold` 0 disables it.
  defp source_sim(fingerprints, norm_hashes, sources, opts) do
    dedup_on = Keyword.get(opts, :dedup_min_shared, 2) not in [nil, 0]
    threshold = Keyword.get(opts, :sim_threshold, 0.8)

    if dedup_on and threshold > 0 do
      pairs = Dedup.candidates(fingerprints, norm_hashes: norm_hashes)
      edges = Dedup.similar_edges(pairs, Map.new(sources), threshold)
      Logger.info("[source-sim] #{length(edges)} similar pairs (jaro>=#{threshold}) from #{length(pairs)} candidates")
      edges
    else
      []
    end
  end

  # Behavioral-equivalence edges (default-on; `--no-behavioral` to skip; runs
  # python). Gates candidate pairs cheaply (Dedup.candidates), loads only those
  # rows' payloads back from disk, then checks bidirectional reproduction. The
  # gold-standard signal: catches duplicates with a *genuinely different*
  # solution (low source similarity), which `source_sim` misses.
  defp behavioral?(opts), do: Keyword.get(opts, :behavioral, true)

  defp behavioral(fingerprints, norm_hashes, results_path, opts) do
    dedup_on = Keyword.get(opts, :dedup_min_shared, 2) not in [nil, 0]

    if dedup_on and behavioral?(opts) do
      pairs = Dedup.candidates(fingerprints, norm_hashes: norm_hashes)
      ids = pairs |> Enum.flat_map(fn {a, b} -> [a, b] end) |> MapSet.new()
      rows = load_rows(results_path, ids)

      edges = Behavioral.edges(rows, pairs, behavioral_opts(opts))
      Logger.info("[behavioral] #{length(edges)} equivalent pairs from #{length(pairs)} candidates")
      edges
    else
      []
    end
  end

  defp behavioral_opts(opts) do
    [
      run_count: Keyword.get(opts, :behavioral_run_count, Keyword.get(opts, :run_count, 5)),
      timeout_ms: Keyword.get(opts, :timeout_ms, 20_000),
      concurrency: Keyword.get(opts, :concurrency, System.schedulers_online())
    ]
  end

  # Load just the candidate rows' payloads (source + testcases) from the
  # on-disk results spill — bounded by the candidate set, not the dataset.
  defp load_rows(results_path, ids) do
    results_path
    |> stream_results()
    |> Stream.filter(&MapSet.member?(ids, &1.id))
    |> Map.new(fn r -> {r.id, %{source: r.source, testcases: r.testcases}} end)
  end

  # Canonical-source hashes for the dedup source signal (Dataset.SourceNorm).
  # `:source_norm` mode: "struct" (default) | "reformat" | "none"/0 (off).
  # Skipped when dedup itself is disabled.
  defp source_norm(sources, opts) do
    mode = Keyword.get(opts, :source_norm, "struct")
    dedup_on = Keyword.get(opts, :dedup_min_shared, 2) not in [nil, 0]

    if dedup_on and to_string(mode) not in ["none", "0", ""] do
      hashes = SourceNorm.hashes(sources, mode: to_string(mode))
      Logger.info("[source-norm] mode=#{mode}: hashed #{map_size(hashes)}/#{length(sources)} sources")
      hashes
    else
      %{}
    end
  end

  defp apply_override(result, overrides) do
    case Map.get(overrides, result.id) do
      nil ->
        result

      o ->
        result
        |> Map.put(:member_qids, o.member_qids)
        |> Map.put(:alternate_solution_shas, o.alternate_solution_shas)
        |> Map.put(:merged_row_count, o.merged_row_count)
    end
  end

  # Length-prefixed term_to_binary records — exact round-trip of a select
  # result, so the heavy testcase payloads live on disk between selection
  # and emit instead of resident.
  defp write_result(handle, result) do
    bin = :erlang.term_to_binary(result)
    :ok = :file.write(handle, <<byte_size(bin)::32, bin::binary>>)
  end

  defp stream_results(path) do
    Stream.resource(
      fn -> File.open!(path, [:read, :binary, :raw]) end,
      fn h ->
        case :file.read(h, 4) do
          {:ok, <<len::32>>} ->
            {:ok, bin} = :file.read(h, len)
            {[:erlang.binary_to_term(bin)], h}

          :eof ->
            {:halt, h}
        end
      end,
      fn h -> File.close(h) end
    )
  end

  # Load one spilled bucket, build its candidate groups, and select
  # concurrently. Memory is bounded by the bucket size.
  defp process_bucket(dir, b, solutions_by_qid, qid_to_group, size_limit, select_opts, concurrency, counter, total) do
    testcases_by_qid = Spill.read_bucket(dir, b)

    if map_size(testcases_by_qid) == 0 do
      []
    else
      sub_qid_to_group = Map.take(qid_to_group, Map.keys(testcases_by_qid))

      solutions_by_qid
      |> Candidates.build(testcases_by_qid, sub_qid_to_group, size_limit: size_limit)
      |> Map.values()
      |> Task.async_stream(
        fn group -> select_with_progress(group, select_opts, counter, total) end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, result}} -> [result]
        {:ok, :drop} -> []
      end)
    end
  end

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

  defp apply_shard(gids, nil), do: gids

  defp apply_shard(gids, {i, n}) do
    Enum.filter(gids, fn gid -> rem(:erlang.phash2(gid, n), n) == i end)
  end

  defp apply_skip_limit(groups, skip, limit) do
    groups
    |> then(fn g -> if skip, do: Enum.drop(g, skip), else: g end)
    |> then(fn g -> if limit, do: Enum.take(g, limit), else: g end)
  end
end
