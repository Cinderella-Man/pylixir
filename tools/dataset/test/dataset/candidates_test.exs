defmodule Dataset.CandidatesTest do
  use ExUnit.Case, async: true

  alias Dataset.Candidates

  defp sol(sha, source), do: %{sha: sha, source: source}
  defp tc(stdin, expected), do: %{stdin: stdin, expected: expected}

  test "merges solution + testcase pools across a group; dedups solutions by sha" do
    solutions = %{
      "A" => [sol("h1", "print(1)"), sol("h2", "print(2)")],
      "B" => [sol("h2", "print(2)"), sol("h3", "print(3)")]
    }

    testcases = %{
      "A" => [tc("1\n", "a\n")],
      "B" => [tc("2\n", "b\n")]
    }

    qid_to_group = %{"A" => "A", "B" => "A"}

    %{"A" => g} = Candidates.build(solutions, testcases, qid_to_group)

    assert g.member_qids == ["A", "B"]
    assert Enum.map(g.solutions, & &1.sha) == ["h1", "h2", "h3"]
    assert Enum.map(g.testcases, & &1.stdin) |> Enum.sort() == ["1\n", "2\n"]
  end

  test "dedups testcases by stdin; collects distinct stored outputs + n_stored_outputs" do
    solutions = %{"A" => [sol("h1", "x")], "B" => [sol("h1", "x")]}
    # same stdin "k\n" with two DIFFERENT stored outputs across members, plus a dup
    testcases = %{
      "A" => [tc("k\n", "v1\n"), tc("k\n", "v1\n")],
      "B" => [tc("k\n", "v2\n")]
    }

    %{"A" => g} = Candidates.build(solutions, testcases, %{"A" => "A", "B" => "A"})

    assert [%{stdin: "k\n", expecteds: exps, n_stored_outputs: 2}] = g.testcases
    assert Enum.sort(exps) == ["v1\n", "v2\n"]
  end

  test "curation size filter drops oversized stdin or expected" do
    big = String.duplicate("x", 50)

    solutions = %{"A" => [sol("h1", "x")]}

    testcases = %{
      "A" => [
        tc("ok\n", "fine\n"),
        # oversized stdin
        tc(big <> "\n", "small\n"),
        # oversized expected
        tc("small\n", big <> "\n")
      ]
    }

    %{"A" => g} = Candidates.build(solutions, testcases, %{"A" => "A"}, size_limit: 10)

    assert Enum.map(g.testcases, & &1.stdin) == ["ok\n"]
  end

  test "group with solutions but all testcases filtered → empty testcases (kept, dropped later)" do
    solutions = %{"A" => [sol("h1", "x")]}
    testcases = %{"A" => [tc(String.duplicate("z", 50) <> "\n", "v\n")]}

    %{"A" => g} = Candidates.build(solutions, testcases, %{"A" => "A"}, size_limit: 10)
    assert g.testcases == []
  end

  test "groups with no solutions are excluded" do
    solutions = %{"A" => [sol("h1", "x")]}
    testcases = %{"A" => [tc("1\n", "a\n")], "Z" => [tc("9\n", "z\n")]}
    # qid Z has testcases but appears with no solution entry
    qid_to_group = %{"A" => "A", "Z" => "Z"}

    result = Candidates.build(solutions, testcases, qid_to_group)
    assert Map.keys(result) == ["A"]
  end
end
