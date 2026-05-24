defmodule Dataset.SelectTest do
  use ExUnit.Case, async: true

  alias Dataset.Select

  defp sol(sha, source), do: %{sha: sha, source: source}

  defp tcs(n) do
    for i <- 1..n, do: %{stdin: "#{i}\n", expecteds: ["o#{i}"], n_stored_outputs: 1}
  end

  defp group(solutions, testcases, gid \\ "seed_1", members \\ ["seed_1"]) do
    %{group_id: gid, member_qids: members, solutions: solutions, testcases: testcases}
  end

  # A verify_fun that keeps the first N testcases, where N is dictated per
  # solution sha via the map. Records which solutions it was asked about.
  defp keeper(keep_by_sha, agent) do
    fn sol, capped, _opts ->
      if agent, do: Agent.update(agent, &[sol.sha | &1])
      n = Map.get(keep_by_sha, sol.sha, 0)
      Enum.take(capped, n)
    end
  end

  test "early-stop: first 100% solution wins and later solutions are never verified" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    # ordered by (len, sha): "aaa"(sha s1) and "bbb"(sha s2) same length → sha order
    g = group([sol("s2", "bbb"), sol("s1", "aaa")], tcs(3))
    vf = keeper(%{"s1" => 3, "s2" => 3}, agent)

    {:ok, res} = Select.select(g, verify_fun: vf)

    assert res.solution_sha256 == "s1"
    # s2 must NOT have been verified (early stop after s1 hit 100%)
    assert Agent.get(agent, & &1) == ["s1"]
  end

  test "max-count fallback when no solution verifies all" do
    g = group([sol("s1", "aaa"), sol("s2", "bbb")], tcs(4))
    vf = keeper(%{"s1" => 1, "s2" => 3}, nil)

    {:ok, res} = Select.select(g, verify_fun: vf)
    assert res.solution_sha256 == "s2"
    assert length(res.testcases) == 3
  end

  test "tie on verified count → shortest source then sha wins" do
    # both keep 2 of 4; "aa" shorter than "bbbb" → "aa" (sha s2) wins over "bbbb"(s1)
    g = group([sol("s1", "bbbb"), sol("s2", "aa")], tcs(4))
    vf = keeper(%{"s1" => 2, "s2" => 2}, nil)

    {:ok, res} = Select.select(g, verify_fun: vf)
    assert res.solution_sha256 == "s2"
  end

  test "drop when no solution verifies any testcase" do
    g = group([sol("s1", "aaa")], tcs(3))
    vf = keeper(%{"s1" => 0}, nil)
    assert Select.select(g, verify_fun: vf) == :drop
  end

  test "drop when there are no testcases" do
    g = group([sol("s1", "aaa")], [])
    assert Select.select(g, verify_fun: keeper(%{}, nil)) == :drop
  end

  test "result fields: id, alternates, member_qids, testcases" do
    g = group([sol("zzz", "aaa"), sol("mmm", "aaa")], tcs(2), "seed_42", ["seed_42", "seed_99"])
    # winner is shortest/sha → both len 3, sha "mmm" < "zzz"
    vf = keeper(%{"mmm" => 2, "zzz" => 2}, nil)

    {:ok, res} = Select.select(g, verify_fun: vf)
    assert res.id == "seed_42--mmm"
    assert res.solution_sha256 == "mmm"
    assert res.alternate_solution_shas == ["zzz"]
    assert res.member_qids == ["seed_42", "seed_99"]
    assert length(res.testcases) == 2
  end

  test "solution cap limits how many solutions are tried (shortest-first)" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    # three solutions, none verifies all; cap to 1 → only the shortest/sha tried
    g = group([sol("s3", "ccc"), sol("s1", "aaa"), sol("s2", "bbb")], tcs(4))
    vf = keeper(%{"s1" => 2, "s2" => 3, "s3" => 1}, agent)

    {:ok, res} = Select.select(g, verify_fun: vf, solution_cap: 1)

    # only s1 (shortest/sha order) considered; s2/s3 never verified
    assert Agent.get(agent, & &1) == ["s1"]
    assert res.solution_sha256 == "s1"
  end

  test "testcase cap limits how many are considered" do
    g = group([sol("s1", "aaa")], tcs(40))
    # keeper keeps all it's given; with cap 32 that's 32
    vf = keeper(%{"s1" => 1000}, nil)

    {:ok, res} = Select.select(g, verify_fun: vf, testcase_cap: 32)
    assert length(res.testcases) == 32
  end
end
