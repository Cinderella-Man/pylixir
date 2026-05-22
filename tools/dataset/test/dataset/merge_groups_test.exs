defmodule Dataset.MergeGroupsTest do
  use ExUnit.Case, async: true
  require Explorer.DataFrame, as: DF

  alias Dataset.MergeGroups, as: MG

  defmodule FakeTC do
    require Explorer.DataFrame, as: DF

    def shard_count(:seed_testcase), do: 2

    # Each shard carries part of A's and B's testcases; together they
    # share 3 agreeing stdins and should merge.
    def read_testcase_shard(0, _qids, _cols) do
      DF.new(
        question_id: ["A", "B"],
        inputs: [Jason.encode!(["1\n", "2\n"]), Jason.encode!(["1\n", "2\n"])],
        outputs: [Jason.encode!(["a\n", "b\n"]), Jason.encode!(["a\n", "b\n"])]
      )
    end

    def read_testcase_shard(1, _qids, _cols) do
      DF.new(
        question_id: ["A", "B"],
        inputs: [Jason.encode!(["3\n"]), Jason.encode!(["3\n"])],
        outputs: [Jason.encode!(["c\n"]), Jason.encode!(["c\n"])]
      )
    end
  end

  # Helpers to build opaque fingerprint maps. Keys are arbitrary (the
  # grouping never inspects real shas) so we use readable tokens.
  defp fp(pairs), do: Map.new(pairs, fn {s, e} -> {s, MapSet.new([e])} end)

  test "≥3 shared stdins with agreeing outputs → merged" do
    fps = %{
      "A" => fp(s1: "x", s2: "y", s3: "z"),
      "B" => fp(s1: "x", s2: "y", s3: "z", s9: "q")
    }

    g = MG.group(fps)
    assert g["A"] == g["B"]
    assert g["A"] == "A"
  end

  test "one disagreement on a shared stdin → NOT merged" do
    fps = %{
      "A" => fp(s1: "x", s2: "y", s3: "z"),
      "B" => fp(s1: "x", s2: "y", s3: "DIFFERENT")
    }

    g = MG.group(fps)
    assert g["A"] == "A"
    assert g["B"] == "B"
  end

  test "fewer than 3 shared stdins → NOT merged (even if all agree)" do
    fps = %{
      "A" => fp(s1: "x", s2: "y"),
      "B" => fp(s1: "x", s2: "y")
    }

    g = MG.group(fps)
    refute g["A"] == g["B"]
  end

  test "transitive closure: A~B, B~C ⇒ one group, even if A and C share nothing" do
    fps = %{
      "C" => fp(s1: "x", s2: "y", s3: "z"),
      "B" => fp(s1: "x", s2: "y", s3: "z", t1: "p", t2: "q", t3: "r"),
      "A" => fp(t1: "p", t2: "q", t3: "r")
    }

    g = MG.group(fps)
    assert g["A"] == g["B"]
    assert g["B"] == g["C"]
    # group id is the min member qid
    assert g["A"] == "A"
  end

  test "singletons map to themselves" do
    fps = %{"solo" => fp(s1: "x", s2: "y", s3: "z")}
    assert MG.group(fps) == %{"solo" => "solo"}
  end

  test "agreement holds when expected-sets intersect (alternate-valid noise)" do
    # B's s3 carries two stored outputs, one matching A's — counts as agree
    fps = %{
      "A" => fp(s1: "x", s2: "y", s3: "z"),
      "B" => %{
        s1: MapSet.new(["x"]),
        s2: MapSet.new(["y"]),
        s3: MapSet.new(["z", "alt"])
      }
    }

    g = MG.group(fps)
    assert g["A"] == g["B"]
  end

  test "build/2 accumulates fingerprints across shards then groups" do
    g = MG.build(["A", "B"], dataset_module: FakeTC)
    assert g["A"] == g["B"]
  end
end
