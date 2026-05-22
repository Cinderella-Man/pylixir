defmodule Dataset.MergeGroups do
  @moduledoc """
  Stage 0 — global near-duplicate **task** grouping. See
  docs/12_dataset-curation-plan.md §Pipeline-0.

  rStar-Coder contains the same problem under multiple `question_id`s
  with tweaked wording (e.g. easy/hard contest variants). Such qids
  should be treated as one task so their solution + testcase pools merge
  (verification later self-heals any over-merge — foreign testcases just
  fail and drop, costing recall not integrity).

  Detection signal is **testcase-output agreement**, never question text:
  two qids are the same task iff they share **≥ `min_shared` stdins** and
  their stored outputs **agree on every shared stdin** (zero
  disagreements). Coincidentally-shared trivial inputs disagree on output
  and so don't merge. Grouping is the **transitive closure** (connected
  components) so easy/medium/hard triples cluster.

  Memory: only `{sha(stdin) => set(sha(expected))}` per qid is retained
  (hashes, no text). And only qids that *have solutions* are
  fingerprinted (a partner without solutions is irrelevant), so the
  testcase reads reuse `Dataset.read_testcase_shard/3`'s qid pushdown.

  `group/2` is pure over opaque fingerprint maps (unit-testable);
  `build/2` adds the shard I/O.
  """

  alias Dataset.Dataset
  require Logger

  @min_shared 3
  # Skip an stdin shared by more qids than this when enumerating pairs:
  # ultra-common inputs (e.g. "") can't form a meaningful agreeing
  # cluster and would explode the pair count quadratically.
  @max_fanout 64

  @type qid :: String.t()
  @type fingerprints :: %{qid() => %{binary() => MapSet.t(binary())}}

  @doc """
  Build the `qid => group_id` map for `qids_with_solutions` by scanning
  testcase shards. `group_id` is the lexicographically smallest member
  qid; singletons map to themselves.

  ## Options
    * `:dataset_module` — default `Dataset.Dataset`.
    * `:testcase_shards` — number of shards to scan (default: all).
    * `:min_shared` — default `#{@min_shared}`.
  """
  @spec build(Enumerable.t(), keyword()) :: %{qid() => qid()}
  def build(qids_with_solutions, opts \\ []) do
    dataset = Keyword.get(opts, :dataset_module, Dataset)
    shards = Keyword.get(opts, :testcase_shards, dataset.shard_count(:seed_testcase))
    min_shared = Keyword.get(opts, :min_shared, @min_shared)

    qids = Enum.to_list(qids_with_solutions)

    fps =
      Enum.reduce(0..(shards - 1), %{}, fn idx, acc ->
        Logger.info("[merge] seed_testcase shard #{idx + 1}/#{shards}")
        df = dataset.read_testcase_shard(idx, qids, ["question_id", "inputs", "outputs"])
        accumulate_fingerprints(df, acc)
      end)

    group(fps, min_shared: min_shared)
  end

  @doc """
  Pure grouping over fingerprint maps: `%{qid => %{stdin_key =>
  MapSet<expected_key>}}` → `%{qid => group_id}`.

  Two qids are unioned iff they share ≥ `:min_shared` stdin keys and have
  **zero** disagreements (a shared stdin whose expected-key sets are
  disjoint). Transitive closure via connected components; `group_id` =
  min member qid.
  """
  @spec group(fingerprints(), keyword()) :: %{qid() => qid()}
  def group(fingerprints, opts \\ []) do
    min_shared = Keyword.get(opts, :min_shared, @min_shared)
    qids = Map.keys(fingerprints)

    {shared, disagree} = pair_stats(fingerprints)

    edges =
      for {pair, count} <- shared,
          count >= min_shared,
          Map.get(disagree, pair, 0) == 0,
          do: pair

    components(qids, edges)
  end

  # --- Fingerprint accumulation ---------------------------------------

  defp accumulate_fingerprints(df, acc) do
    require Explorer.DataFrame, as: DF

    qids = df |> DF.pull("question_id") |> Explorer.Series.to_list()
    inputs = df |> DF.pull("inputs") |> Explorer.Series.to_list()
    outputs = df |> DF.pull("outputs") |> Explorer.Series.to_list()

    [qids, inputs, outputs]
    |> Enum.zip()
    |> Enum.reduce(acc, fn
      {qid, inp, out}, acc
      when is_binary(qid) and is_binary(inp) and is_binary(out) ->
        add_pairs(acc, qid, parse_pairs(inp, out))

      _, acc ->
        acc
    end)
  end

  defp parse_pairs(inputs_json, outputs_json) do
    with {:ok, ins} <- Jason.decode(inputs_json),
         {:ok, outs} <- Jason.decode(outputs_json),
         true <- is_list(ins) and is_list(outs) and length(ins) == length(outs) do
      ins
      |> Enum.zip(outs)
      |> Enum.flat_map(fn
        {s, e} when is_binary(s) and is_binary(e) -> [{sha(s), sha(e)}]
        _ -> []
      end)
    else
      _ -> []
    end
  end

  defp add_pairs(acc, qid, pairs) do
    Enum.reduce(pairs, acc, fn {stdin_sha, exp_sha}, acc ->
      Map.update(
        acc,
        qid,
        %{stdin_sha => MapSet.new([exp_sha])},
        fn per_qid ->
          Map.update(per_qid, stdin_sha, MapSet.new([exp_sha]), &MapSet.put(&1, exp_sha))
        end
      )
    end)
  end

  defp sha(s), do: :crypto.hash(:sha256, s)

  # --- Pair statistics via inverted index -----------------------------

  defp pair_stats(fingerprints) do
    # stdin_key => [{qid, expected_set}, …]
    inv =
      Enum.reduce(fingerprints, %{}, fn {qid, per_qid}, inv ->
        Enum.reduce(per_qid, inv, fn {stdin_key, exp_set}, inv ->
          Map.update(inv, stdin_key, [{qid, exp_set}], &[{qid, exp_set} | &1])
        end)
      end)

    Enum.reduce(inv, {%{}, %{}}, fn {_stdin_key, entries}, {shared, disagree} ->
      n = length(entries)

      if n < 2 or n > @max_fanout do
        {shared, disagree}
      else
        tally_pairs(entries, shared, disagree)
      end
    end)
  end

  defp tally_pairs(entries, shared, disagree) do
    entries = Enum.sort_by(entries, &elem(&1, 0))

    pairs(entries)
    |> Enum.reduce({shared, disagree}, fn {{a, a_set}, {b, b_set}}, {shared, disagree} ->
      key = {a, b}
      shared = Map.update(shared, key, 1, &(&1 + 1))

      disagree =
        if MapSet.disjoint?(a_set, b_set),
          do: Map.update(disagree, key, 1, &(&1 + 1)),
          else: disagree

      {shared, disagree}
    end)
  end

  defp pairs([]), do: []
  defp pairs([h | t]), do: Enum.map(t, &{h, &1}) ++ pairs(t)

  # --- Connected components -------------------------------------------

  defp components(qids, edges) do
    adj =
      Enum.reduce(edges, %{}, fn {a, b}, adj ->
        adj
        |> Map.update(a, MapSet.new([b]), &MapSet.put(&1, b))
        |> Map.update(b, MapSet.new([a]), &MapSet.put(&1, a))
      end)

    {map, _seen} =
      Enum.reduce(qids, {%{}, MapSet.new()}, fn qid, {map, seen} ->
        if MapSet.member?(seen, qid) do
          {map, seen}
        else
          component = bfs(qid, adj)
          gid = Enum.min(component)
          map = Enum.reduce(component, map, &Map.put(&2, &1, gid))
          {map, MapSet.union(seen, MapSet.new(component))}
        end
      end)

    map
  end

  defp bfs(start, adj), do: bfs([start], adj, MapSet.new([start]))

  defp bfs([], _adj, seen), do: MapSet.to_list(seen)

  defp bfs([node | queue], adj, seen) do
    neighbours = Map.get(adj, node, MapSet.new())
    new = MapSet.difference(neighbours, seen)
    bfs(queue ++ MapSet.to_list(new), adj, MapSet.union(seen, new))
  end
end
