defmodule Dataset.Candidates do
  @moduledoc """
  Stage 1 — regroup the per-qid corpus by merge-group into per-task
  candidate pools. See docs/12_dataset-curation-plan.md §Pipeline-1.

  For each merge-group (from `Dataset.MergeGroups`):

    * **solution pool** = union of members' solutions, deduped by sha,
      sorted by sha.
    * **testcase pool** = union of members' testcases, **deduped by
      stdin**. Each surviving stdin carries the set of distinct stored
      `expecteds` (correctness later matches *any* of them — rStar noise /
      alternate-valid) and `n_stored_outputs` (= that count, the
      ambiguity signal that ships in `meta`).
    * **curation size filter** — drop a testcase if `stdin > 1 MB` or any
      stored `expected > 1 MB` (the rStar I/O tail reaches tens of MB and
      bloats the dataset / downstream eval). Cheap, from raw sizes.

  Testcases are returned sorted by `sha(stdin)` so the later 32-cap
  (`Dataset.Verify`) is deterministic.
  """

  # 1 MB.
  @size_limit 1024 * 1024

  @type solution :: %{sha: String.t(), source: String.t()}
  @type candidate_testcase :: %{
          stdin: String.t(),
          expecteds: [String.t()],
          n_stored_outputs: pos_integer()
        }
  @type group :: %{
          group_id: String.t(),
          member_qids: [String.t()],
          solutions: [solution()],
          testcases: [candidate_testcase()]
        }

  @doc """
  Build per-group candidate pools.

  ## Arguments
    * `solutions_by_qid` — `%{qid => [%{sha, source}]}` (from `Corpus.grouped/1`).
    * `testcases_by_qid` — `%{qid => [%{stdin, expected}]}`.
    * `qid_to_group` — `%{qid => group_id}` (from `MergeGroups`).

  ## Options
    * `:size_limit` — max bytes for stdin / each stored expected (default 1 MB).

  Returns `%{group_id => group()}`, only for groups that have ≥1 solution.
  """
  @spec build(map(), map(), %{String.t() => String.t()}, keyword()) :: %{String.t() => group()}
  def build(solutions_by_qid, testcases_by_qid, qid_to_group, opts \\ []) do
    limit = Keyword.get(opts, :size_limit, @size_limit)

    members_by_group =
      Enum.reduce(qid_to_group, %{}, fn {qid, gid}, acc ->
        Map.update(acc, gid, [qid], &[qid | &1])
      end)

    members_by_group
    |> Enum.map(fn {gid, member_qids} ->
      member_qids = Enum.sort(member_qids)
      solutions = collect_solutions(member_qids, solutions_by_qid)
      testcases = collect_testcases(member_qids, testcases_by_qid, limit)

      {gid,
       %{
         group_id: gid,
         member_qids: member_qids,
         solutions: solutions,
         testcases: testcases
       }}
    end)
    |> Enum.reject(fn {_gid, g} -> g.solutions == [] end)
    |> Map.new()
  end

  @doc "Default curation size limit in bytes."
  @spec size_limit() :: pos_integer()
  def size_limit, do: @size_limit

  # --- Internals -------------------------------------------------------

  defp collect_solutions(member_qids, solutions_by_qid) do
    member_qids
    |> Enum.flat_map(&Map.get(solutions_by_qid, &1, []))
    |> Enum.uniq_by(& &1.sha)
    |> Enum.sort_by(& &1.sha)
  end

  defp collect_testcases(member_qids, testcases_by_qid, limit) do
    member_qids
    |> Enum.flat_map(&Map.get(testcases_by_qid, &1, []))
    # group by stdin → distinct stored expecteds, preserving first-seen order
    |> Enum.reduce(%{}, fn %{stdin: stdin, expected: expected}, acc ->
      Map.update(acc, stdin, [expected], fn exps ->
        if expected in exps, do: exps, else: exps ++ [expected]
      end)
    end)
    |> Enum.reject(fn {stdin, expecteds} -> oversized?(stdin, expecteds, limit) end)
    |> Enum.map(fn {stdin, expecteds} ->
      %{stdin: stdin, expecteds: expecteds, n_stored_outputs: length(expecteds)}
    end)
    |> Enum.sort_by(fn %{stdin: stdin} -> :crypto.hash(:sha256, stdin) end)
  end

  defp oversized?(stdin, expecteds, limit) do
    byte_size(stdin) > limit or Enum.any?(expecteds, &(byte_size(&1) > limit))
  end
end
