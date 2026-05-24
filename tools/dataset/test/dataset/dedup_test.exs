defmodule Dataset.DedupTest do
  use ExUnit.Case, async: true

  alias Dataset.Dedup

  defp result(id, source, tcs, opts \\ []) do
    %{
      id: id,
      source: source,
      solution_sha256: Keyword.get(opts, :sha, "sha_" <> id),
      testcases: Enum.map(tcs, fn {s, e} -> %{stdin: s, expected: e, n_stored_outputs: 1} end),
      member_qids: Keyword.get(opts, :member_qids, [id]),
      alternate_solution_shas: Keyword.get(opts, :alts, [])
    }
  end

  defp cluster(results, opts) do
    results |> Enum.map(&Dedup.fingerprint/1) |> Dedup.cluster(opts)
  end

  test "distinct tasks are all kept" do
    rs = [
      result("a", "print(1)", [{"1\n", "1\n"}, {"2\n", "2\n"}]),
      result("b", "print(2)", [{"x\n", "y\n"}, {"p\n", "q\n"}])
    ]

    {keep, overrides} = cluster(rs, min_shared: 2)
    assert MapSet.equal?(keep, MapSet.new(["a", "b"]))
    assert overrides == %{}
  end

  test "identical source merges even with zero testcase overlap" do
    rs = [
      result("a", "print(n)", [{"1\n", "1\n"}]),
      result("b", "print(n)", [{"99\n", "99\n"}], sha: "shb")
    ]

    {keep, overrides} = cluster(rs, min_shared: 2)
    assert MapSet.size(keep) == 1
    [{_rep, ov}] = Map.to_list(overrides)
    assert ov.merged_row_count == 2
    assert ov.member_qids == ["a", "b"]
    # the dropped row's sha is recorded as an alternate
    assert "shb" in ov.alternate_solution_shas or "sha_a" in ov.alternate_solution_shas
  end

  test "L2: >=2 shared agreeing stdins merge; a single shared stdin does not" do
    two_shared = [
      result("a", "s1", [{"1\n", "A\n"}, {"2\n", "B\n"}, {"3\n", "C\n"}]),
      result("b", "s2", [{"1\n", "A\n"}, {"2\n", "B\n"}, {"9\n", "Z\n"}])
    ]

    {keep, _} = cluster(two_shared, min_shared: 2)
    assert MapSet.size(keep) == 1

    one_shared = [
      result("a", "s1", [{"1\n", "A\n"}, {"2\n", "B\n"}]),
      result("b", "s2", [{"1\n", "A\n"}, {"7\n", "Q\n"}])
    ]

    {keep, _} = cluster(one_shared, min_shared: 2)
    assert MapSet.size(keep) == 2
  end

  test "disagreement on a shared stdin blocks the merge" do
    rs = [
      result("a", "s1", [{"1\n", "A\n"}, {"2\n", "B\n"}, {"3\n", "C\n"}]),
      result("b", "s2", [{"1\n", "A\n"}, {"2\n", "DIFFERENT\n"}, {"3\n", "C\n"}])
    ]

    {keep, _} = cluster(rs, min_shared: 2)
    assert MapSet.size(keep) == 2
  end

  test "representative is the row with the most testcases" do
    rs = [
      result("a", "s1", [{"1\n", "A\n"}, {"2\n", "B\n"}]),
      result("b", "s2", [{"1\n", "A\n"}, {"2\n", "B\n"}, {"3\n", "C\n"}])
    ]

    {keep, _} = cluster(rs, min_shared: 2)
    assert MapSet.equal?(keep, MapSet.new(["b"]))
  end

  test "norm_hashes signal merges rows with the same canonical-source hash" do
    rs = [
      result("a", "s = input()\nprint(s)", [{"1\n", "1\n"}]),
      result("b", "n = input()\nprint(n)", [{"99\n", "99\n"}], sha: "shb"),
      result("c", "print('unrelated')", [{"x\n", "y\n"}], sha: "shc")
    ]

    # a and b share a canonical hash; c is distinct. No testcase overlap.
    norm = %{"a" => "HASH1", "b" => "HASH1", "c" => "HASH2"}
    {keep, overrides} = cluster(rs, min_shared: 2, norm_hashes: norm)

    assert MapSet.size(keep) == 2
    [{_rep, ov}] = Map.to_list(overrides)
    assert ov.merged_row_count == 2
    assert ov.member_qids == ["a", "b"]
  end

  test "nil norm hash forms no edge" do
    rs = [
      result("a", "x", [{"1\n", "1\n"}]),
      result("b", "y", [{"2\n", "2\n"}], sha: "shb")
    ]

    {keep, _} = cluster(rs, min_shared: 2, norm_hashes: %{"a" => nil, "b" => nil})
    assert MapSet.size(keep) == 2
  end

  test "extra_edges union arbitrary id pairs (e.g. behavioral equivalence)" do
    rs = [
      result("a", "s1", [{"1\n", "A\n"}]),
      result("b", "s2", [{"9\n", "Z\n"}], sha: "shb")
    ]

    # no intrinsic signal links a,b; an extra edge merges them
    {keep, overrides} = cluster(rs, min_shared: 2, extra_edges: [{"a", "b"}])
    assert MapSet.size(keep) == 1
    [{_rep, ov}] = Map.to_list(overrides)
    assert ov.member_qids == ["a", "b"]
  end

  test "candidates: surfaces single-shared and seed-adjacent pairs, skips already-merged" do
    rs = [
      # single shared stdin "1\n" (agree) with b -> candidate
      result("seed_1", "s1", [{"1\n", "X\n"}, {"a\n", "A\n"}]),
      result("seed_2", "s2", [{"1\n", "X\n"}, {"b\n", "B\n"}], sha: "shb"),
      # seed-adjacent to seed_2 (3 vs 2), no shared tc -> candidate
      result("seed_3", "s3", [{"c\n", "C\n"}], sha: "shc"),
      # shares 2 stdins with seed_1 -> already merged, NOT a candidate
      result("seed_50", "s50", [{"1\n", "X\n"}, {"a\n", "A\n"}], sha: "sh50")
    ]

    fps = Enum.map(rs, &Dedup.fingerprint/1)
    cand = Dedup.candidates(fps) |> Enum.map(&Enum.sort(Tuple.to_list(&1))) |> Enum.sort()

    assert ["seed_1", "seed_2"] in cand
    assert ["seed_2", "seed_3"] in cand
    # seed_1/seed_50 share 2 stdins → already merged → excluded
    refute ["seed_1", "seed_50"] in cand
  end

  test "transitive closure clusters a->b->c" do
    rs = [
      result("a", "s1", [{"1\n", "A\n"}, {"2\n", "B\n"}]),
      result("b", "s2", [{"2\n", "B\n"}, {"3\n", "C\n"}]),
      result("c", "s3", [{"3\n", "C\n"}, {"4\n", "D\n"}])
    ]

    # a-b share {2}, b-c share {3}: with min_shared 1 they chain into one.
    {keep, overrides} = cluster(rs, min_shared: 1)
    assert MapSet.size(keep) == 1
    [{_rep, ov}] = Map.to_list(overrides)
    assert ov.merged_row_count == 3
  end

  describe "similar_edges/3" do
    test "keeps pairs with similar source, drops dissimilar" do
      sources = %{
        "a" => "for c in price:\n    if c not in {'8', '5', '3'}:\n        valid = False",
        "b" => "for c in price:\n    if c not in {'3', '5', '8'}:\n        valid = False",
        "c" => "print(sum(map(int, input().split())))"
      }

      assert Dedup.similar_edges([{"a", "b"}, {"a", "c"}], sources, 0.8) == [{"a", "b"}]
    end

    test "drops pairs with a missing source" do
      assert Dedup.similar_edges([{"a", "b"}], %{"a" => "print(1)"}, 0.8) == []
    end

    test "threshold gates the cutoff" do
      sources = %{"a" => "print(1)", "b" => "print(2)"}
      assert Dedup.similar_edges([{"a", "b"}], sources, 0.99) == []
      assert Dedup.similar_edges([{"a", "b"}], sources, 0.5) == [{"a", "b"}]
    end

    test "similar_candidates surfaces content-similar pairs regardless of seeds" do
      base = """
      import sys
      def main():
          data = sys.stdin.read().split()
          n = int(data[0])
          total = 0
          for i in range(1, n + 1):
              total += int(data[i])
          print(total)
      main()
      """

      sources = %{
        # near-identical to base (only a var name + comment differ)
        "seed_4498" => base,
        "seed_9207" => String.replace(base, "total", "acc") <> "# variant\n",
        # unrelated program
        "seed_1" => "print(input()[::-1])"
      }

      pairs = Dedup.similar_candidates(sources, min_jaccard: 0.5)
      assert {"seed_4498", "seed_9207"} in pairs
      refute Enum.any?(pairs, fn {a, b} -> "seed_1" in [a, b] end)
    end

    test "similar_edges feed cluster as extra_edges (zero testcase overlap)" do
      rs = [
        result("a", "for c in p:\n    if c not in {'8','5','3'}: x=1", [{"1\n", "A\n"}]),
        result("b", "for c in p:\n    if c not in {'3','5','8'}: x=1", [{"9\n", "Z\n"}], sha: "shb")
      ]

      fps = Enum.map(rs, &Dedup.fingerprint/1)
      sources = Map.new(rs, fn r -> {r.id, r.source} end)
      edges = Dedup.similar_edges([{"a", "b"}], sources, 0.8)
      assert edges == [{"a", "b"}]

      {keep, overrides} = Dedup.cluster(fps, min_shared: 2, extra_edges: edges)
      assert MapSet.size(keep) == 1
      [{_rep, ov}] = Map.to_list(overrides)
      assert ov.merged_row_count == 2
    end
  end
end
