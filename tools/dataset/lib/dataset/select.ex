defmodule Dataset.Select do
  @moduledoc """
  Stage 3 — pick ONE canonical solution per merge-group. See
  docs/12_dataset-curation-plan.md §Pipeline-3.

  The testcase pool is capped to `:testcase_cap` (default 32) by taking
  the first N (the pool arrives sorted by `sha(stdin)` from
  `Dataset.Candidates`, so the cap is deterministic).

  Solutions are tried in **(shortest source, then sha)** order, with an
  **early-stop**: the first solution that verifies *all* capped testcases
  is provably optimal (you can't beat "all"), so the rest are never run —
  in the common case (`is_passed=true` solutions are mostly correct) this
  collapses ~16 candidates to ~1–2. If none verifies all, it falls back
  to the solution with the **maximum** verified count (ties broken by the
  iteration order itself: shortest source, then sha).

  Ships the winner + its verified testcases; records the other solutions'
  shas as `alternate_solution_shas`. Drops the group if no solution
  verifies ≥1 testcase (or there are no testcases).

  Verification is delegated to `Dataset.Verify.verify_solution/3`,
  overridable via `:verify_fun` for testing the selection logic alone.
  """

  alias Dataset.Verify

  @testcase_cap 32
  # Cap candidate solutions per task. Merged near-dup groups can pool
  # hundreds of solutions; verifying them all (× testcases) is the main
  # cost blow-up. Solutions are tried shortest-first, so a concise correct
  # one is almost always within the cap.
  @solution_cap 100

  @type result :: %{
          id: String.t(),
          source: String.t(),
          solution_sha256: String.t(),
          testcases: [map()],
          member_qids: [String.t()],
          alternate_solution_shas: [String.t()]
        }

  @doc """
  Select the canonical solution for a `Dataset.Candidates` group. Returns
  `{:ok, result}` or `:drop`.

  ## Options
    * `:testcase_cap` (default #{@testcase_cap})
    * `:solution_cap` (default #{@solution_cap}) — max candidate solutions tried (shortest-first).
    * `:verify_fun` — `(solution, testcases, opts -> [kept])`; default
      `&Dataset.Verify.verify_solution/3`.
    * other opts are passed through to the verify function.
  """
  @spec select(map(), keyword()) :: {:ok, result()} | :drop
  def select(group, opts \\ []) do
    cap = Keyword.get(opts, :testcase_cap, @testcase_cap)
    sol_cap = Keyword.get(opts, :solution_cap, @solution_cap)
    verify_fun = Keyword.get(opts, :verify_fun, &Verify.verify_solution/3)

    capped = Enum.take(group.testcases, cap)

    ordered =
      group.solutions
      |> Enum.sort_by(fn s -> {byte_size(s.source), s.sha} end)
      |> Enum.take(sol_cap)

    case capped do
      [] -> :drop
      _ -> choose(group, ordered, capped, length(capped), verify_fun, opts)
    end
  end

  # --- Internals -------------------------------------------------------

  defp choose(group, ordered, capped, total, verify_fun, opts) do
    best =
      Enum.reduce_while(ordered, nil, fn sol, best ->
        kept = verify_fun.(sol, capped, opts)
        n = length(kept)

        cond do
          # provably optimal — stop, the rest can't beat "all"
          n == total -> {:halt, {sol, kept}}
          n > kept_count(best) -> {:cont, {sol, kept}}
          true -> {:cont, best}
        end
      end)

    case best do
      {sol, kept} when kept != [] -> {:ok, build_result(group, sol, kept, ordered)}
      _ -> :drop
    end
  end

  defp kept_count(nil), do: -1
  defp kept_count({_sol, kept}), do: length(kept)

  defp build_result(group, sol, kept, ordered) do
    sha8 = String.slice(sol.sha, 0, 8)

    alternates =
      ordered
      |> Enum.reject(&(&1.sha == sol.sha))
      |> Enum.map(& &1.sha)
      |> Enum.sort()

    %{
      id: "#{group.group_id}--#{sha8}",
      source: sol.source,
      solution_sha256: sol.sha,
      testcases: kept,
      member_qids: group.member_qids,
      alternate_solution_shas: alternates
    }
  end
end
