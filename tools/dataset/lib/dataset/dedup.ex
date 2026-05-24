defmodule Dataset.Dedup do
  @moduledoc """
  Post-selection global dedup of the chosen rows. A second, stricter
  pass on top of `Dataset.MergeGroups`: that stage merges qids on **raw**
  stored outputs with a fanout cap *before* verification; this one merges
  the **shipped** rows (normalized, verified, 32-capped testcases) with no
  fanout cap, catching variations the merge missed (see
  docs/12_dataset-curation-plan.md §Pipeline-0).

  Two rows are unioned (transitive closure → connected components) iff
  **any** of:

    * identical solution source, or
    * identical **canonical** source — same `:norm_hashes` entry, supplied
      by `Dataset.SourceNorm` (catches comment/whitespace/rename-only
      variations); off unless `:norm_hashes` is passed, or
    * identical full testcase-set (`{stdin, expected}`), or
    * **≥ `:min_shared` shared stdins with zero disagreeing outputs**.

  The zero-disagreement requirement already excludes coincidental
  trivial-input collisions, so — unlike the merge stage — there is no
  fanout cap (the survivor set is small and 32-capped, so pair counting is
  bounded). `min_shared: 2` is the curated default ("L2"); `1` is maximal;
  `3` matches the merge rule.

  Per cluster the **representative** is the row with the most testcases
  (ties: shortest source, then `id`); the dropped rows' `member_qids` and
  solution shas fold into its meta so attribution survives.

  Works on opaque *fingerprints* (hashes + small meta only, never the
  testcase payloads) so it stays memory-cheap regardless of dataset size;
  the build keeps the full rows on disk and re-reads only the survivors.
  """

  @type fingerprint :: %{
          id: String.t(),
          source_sha: binary(),
          source_len: non_neg_integer(),
          ntc: non_neg_integer(),
          io: %{binary() => binary()},
          full_sig: binary(),
          member_qids: [String.t()],
          solution_sha256: String.t(),
          alternate_solution_shas: [String.t()]
        }

  @type override :: %{
          member_qids: [String.t()],
          alternate_solution_shas: [String.t()],
          merged_row_count: pos_integer()
        }

  @doc """
  Lightweight fingerprint of a `Dataset.Select` result — hashes and small
  meta only, never the stdin/expected text.
  """
  @spec fingerprint(map()) :: fingerprint()
  def fingerprint(result) do
    io = Map.new(result.testcases, fn tc -> {sha(tc.stdin), sha(tc.expected)} end)

    %{
      id: result.id,
      source_sha: sha(result.source),
      source_len: byte_size(result.source),
      ntc: length(result.testcases),
      io: io,
      full_sig: :crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(io))),
      member_qids: result.member_qids,
      solution_sha256: result.solution_sha256,
      alternate_solution_shas: result.alternate_solution_shas
    }
  end

  @doc """
  Cluster fingerprints and return `{keep, overrides}`:

    * `keep` — `MapSet` of representative ids to ship.
    * `overrides` — `%{rep_id => override}` for clusters that merged
      (>1 member); the build replaces the representative's `member_qids`
      / `alternate_solution_shas` and stamps `merged_row_count`.

  ## Options
    * `:min_shared` — default 2.
    * `:norm_hashes` — `%{id => canonical_source_hash}` from
      `Dataset.SourceNorm`; rows with the same hash are unioned. Default `%{}`.
    * `:extra_edges` — `[{id, id}]` precomputed edges to union in (e.g.
      behavioral-equivalence pairs from `Dataset.Behavioral`). Default `[]`.
  """
  @spec cluster([fingerprint()], keyword()) :: {MapSet.t(String.t()), %{String.t() => override()}}
  def cluster(fingerprints, opts \\ []) do
    min_shared = Keyword.get(opts, :min_shared, 2)
    norm = Keyword.get(opts, :norm_hashes, %{})
    fps = fingerprints |> Enum.with_index() |> Map.new(fn {fp, i} -> {i, fp} end)
    n = map_size(fps)

    edges =
      exact_edges(fps, n) ++
        norm_edges(fps, n, norm) ++
        tc_edges(fps, n, min_shared) ++
        id_edges(fps, n, Keyword.get(opts, :extra_edges, []))

    n
    |> components(edges)
    |> Enum.reduce({MapSet.new(), %{}}, fn comp, {keep, overrides} ->
      members = Enum.map(comp, &Map.fetch!(fps, &1))
      rep = Enum.min_by(members, fn m -> {-m.ntc, m.source_len, m.id} end)
      keep = MapSet.put(keep, rep.id)

      if length(members) > 1 do
        {keep, Map.put(overrides, rep.id, merged_override(members, rep))}
      else
        {keep, overrides}
      end
    end)
  end

  @doc """
  Candidate id-pairs for the (expensive) behavioral-equivalence check
  (`Dataset.Behavioral`). Gated cheaply so we never test all pairs:

    * rows sharing **exactly 1** stdin with agreeing output (the L3 tier;
      ≥2-shared already merge via `cluster/2`), and
    * rows whose `member_qids` contain **numerically adjacent** seed ids
      (LLM variations were generated with consecutive question ids).

  Pairs that are already merged by a cheap signal (identical source /
  canonical source / testcase-set, or ≥2 shared stdins) are excluded.

  ## Options
    * `:norm_hashes` — same map as `cluster/2`, to skip canonical-source dups.
  """
  @spec candidates([fingerprint()], keyword()) :: [{String.t(), String.t()}]
  def candidates(fingerprints, opts \\ []) do
    norm = Keyword.get(opts, :norm_hashes, %{})
    fps = fingerprints |> Enum.with_index() |> Map.new(fn {fp, i} -> {i, fp} end)
    n = map_size(fps)

    {shared, disagree} = pair_stats(fps, n)
    one_shared = for {{i, j}, 1} <- shared, not MapSet.member?(disagree, {i, j}), do: {i, j}
    adjacent = seed_adjacent_pairs(fps, n)

    (one_shared ++ adjacent)
    |> MapSet.new()
    |> Enum.reject(fn {i, j} -> already_merged?(fps, norm, shared, i, j) end)
    |> Enum.map(fn {i, j} -> {Map.fetch!(fps, i).id, Map.fetch!(fps, j).id} end)
  end

  # Pairwise shared/disagree counts over the stdin inverted index.
  defp pair_stats(fps, n) do
    inv =
      Enum.reduce(0..(n - 1)//1, %{}, fn i, inv ->
        Enum.reduce(Map.fetch!(fps, i).io, inv, fn {stdin, _}, inv ->
          Map.update(inv, stdin, [i], &[i | &1])
        end)
      end)

    Enum.reduce(inv, {%{}, MapSet.new()}, fn
      {_stdin, [_only]}, acc -> acc
      {stdin, idxs}, acc -> tally(Enum.sort(idxs), stdin, fps, acc)
    end)
  end

  defp seed_adjacent_pairs(fps, n) do
    seed_to_idx =
      Enum.reduce(0..(n - 1)//1, %{}, fn i, acc ->
        Enum.reduce(Map.fetch!(fps, i).member_qids, acc, fn qid, acc ->
          case Regex.run(~r/^seed_(\d+)$/, qid) do
            [_, num] -> Map.put(acc, String.to_integer(num), i)
            _ -> acc
          end
        end)
      end)

    for {num, i} <- seed_to_idx,
        j = Map.get(seed_to_idx, num + 1),
        is_integer(j) and j != i,
        do: {min(i, j), max(i, j)}
  end

  defp already_merged?(fps, norm, shared, i, j) do
    a = Map.fetch!(fps, i)
    b = Map.fetch!(fps, j)

    a.source_sha == b.source_sha or
      a.full_sig == b.full_sig or
      norm_equal?(norm, a.id, b.id) or
      Map.get(shared, {i, j}, 0) >= 2
  end

  defp norm_equal?(norm, a_id, b_id) do
    case Map.get(norm, a_id) do
      nil -> false
      hash -> hash == Map.get(norm, b_id)
    end
  end

  # --- Edges -----------------------------------------------------------

  # Map precomputed id-pairs to index edges (ids not present are dropped).
  defp id_edges(fps, n, id_pairs) do
    id_to_idx = Map.new(0..(n - 1)//1, fn i -> {Map.fetch!(fps, i).id, i} end)

    for {a, b} <- id_pairs,
        ia = Map.get(id_to_idx, a),
        ib = Map.get(id_to_idx, b),
        is_integer(ia) and is_integer(ib),
        do: {min(ia, ib), max(ia, ib)}
  end

  # Chain indices that share a key (source_sha, then full_sig) into edges.
  defp exact_edges(fps, n) do
    Enum.flat_map([:source_sha, :full_sig], fn key ->
      0..(n - 1)//1
      |> Enum.group_by(fn i -> Map.get(Map.fetch!(fps, i), key) end)
      |> Enum.flat_map(fn {_k, [h | t]} -> Enum.map(t, &{min(h, &1), max(h, &1)}) end)
    end)
  end

  # Chain indices whose canonical-source hash matches (skips unhashed ids).
  defp norm_edges(_fps, _n, norm) when map_size(norm) == 0, do: []

  defp norm_edges(fps, n, norm) do
    0..(n - 1)//1
    |> Enum.group_by(fn i -> Map.get(norm, Map.fetch!(fps, i).id) end)
    |> Enum.flat_map(fn
      {nil, _} -> []
      {_hash, [h | t]} -> Enum.map(t, &{min(h, &1), max(h, &1)})
    end)
  end

  # Edges between rows sharing >= min_shared stdins with zero disagreements.
  defp tc_edges(fps, n, min_shared) do
    {shared, disagree} = pair_stats(fps, n)
    for {pair, count} <- shared, count >= min_shared, not MapSet.member?(disagree, pair), do: pair
  end

  defp tally(idxs, stdin_sha, fps, init) do
    exp = Map.new(idxs, fn i -> {i, Map.fetch!(Map.fetch!(fps, i).io, stdin_sha)} end)

    idxs
    |> pairs()
    |> Enum.reduce(init, fn {a, b}, {shared, disagree} ->
      shared = Map.update(shared, {a, b}, 1, &(&1 + 1))

      disagree =
        if Map.fetch!(exp, a) == Map.fetch!(exp, b),
          do: disagree,
          else: MapSet.put(disagree, {a, b})

      {shared, disagree}
    end)
  end

  defp pairs([]), do: []
  defp pairs([h | t]), do: Enum.map(t, &{h, &1}) ++ pairs(t)

  # --- Connected components (BFS over adjacency) -----------------------

  defp components(0, _edges), do: []

  defp components(n, edges) do
    adj =
      Enum.reduce(edges, %{}, fn {a, b}, adj ->
        adj
        |> Map.update(a, [b], &[b | &1])
        |> Map.update(b, [a], &[a | &1])
      end)

    {comps, _seen} =
      Enum.reduce(0..(n - 1)//1, {[], MapSet.new()}, fn i, {comps, seen} ->
        if MapSet.member?(seen, i) do
          {comps, seen}
        else
          comp = bfs([i], adj, MapSet.new([i]))
          {[comp | comps], MapSet.union(seen, MapSet.new(comp))}
        end
      end)

    comps
  end

  defp bfs([], _adj, seen), do: MapSet.to_list(seen)

  defp bfs([node | queue], adj, seen) do
    new = adj |> Map.get(node, []) |> Enum.reject(&MapSet.member?(seen, &1))
    bfs(queue ++ new, adj, MapSet.union(seen, MapSet.new(new)))
  end

  # --- Merge meta ------------------------------------------------------

  defp merged_override(members, rep) do
    member_qids = members |> Enum.flat_map(& &1.member_qids) |> Enum.uniq() |> Enum.sort()

    alternates =
      members
      |> Enum.flat_map(fn m -> [m.solution_sha256 | m.alternate_solution_shas] end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == rep.solution_sha256))
      |> Enum.sort()

    %{member_qids: member_qids, alternate_solution_shas: alternates, merged_row_count: length(members)}
  end

  defp sha(s), do: :crypto.hash(:sha256, s)
end
