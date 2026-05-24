defmodule Dataset.BehavioralTest do
  use ExUnit.Case, async: true

  alias Dataset.Behavioral

  defp row(source, tcs) do
    %{source: source, testcases: Enum.map(tcs, fn {s, e} -> %{stdin: s, expected: e} end)}
  end

  # Stub verdict_fun: each "solution" is a map %{stdin => canonical_output};
  # unknown stdin => rejected. Lets us test the equivalence logic without python.
  defp vf(behaviours) do
    fn source, stdin, _opts ->
      case Map.fetch(Map.fetch!(behaviours, source), stdin) do
        {:ok, out} -> {:reproducible, out}
        :error -> {:rejected, :error}
      end
    end
  end

  test "equivalent when each solution reproduces all of the other's testcases" do
    beh = %{
      "A" => %{"1" => "one", "2" => "two"},
      "B" => %{"1" => "one", "2" => "two"}
    }

    a = row("A", [{"1", "one"}])
    b = row("B", [{"2", "two"}])

    assert Behavioral.equivalent?(a, b, verdict_fun: vf(beh))
  end

  test "not equivalent if one solution produces a different answer on the other's input" do
    beh = %{
      "A" => %{"1" => "one", "9" => "NINE"},
      "B" => %{"1" => "one", "9" => "different"}
    }

    a = row("A", [{"9", "NINE"}])
    b = row("B", [{"9", "different"}])

    refute Behavioral.equivalent?(a, b, verdict_fun: vf(beh))
  end

  test "not equivalent if a solution rejects (errors/times out) on the other's input" do
    beh = %{"A" => %{"1" => "one"}, "B" => %{}}
    a = row("A", [{"1", "one"}])
    b = row("B", [{"1", "one"}])

    # B can't reproduce A's testcase (its stdin is unknown → rejected)
    refute Behavioral.equivalent?(a, b, verdict_fun: vf(beh))
  end

  test "edges/3 returns only the equivalent candidate pairs" do
    beh = %{
      "A" => %{"x" => "1", "y" => "2"},
      "B" => %{"x" => "1", "y" => "2"},
      "C" => %{"z" => "99"}
    }

    rows = %{"A" => row("A", [{"x", "1"}]), "B" => row("B", [{"y", "2"}]), "C" => row("C", [{"z", "99"}])}
    pairs = [{"A", "B"}, {"A", "C"}]

    edges = Behavioral.edges(rows, pairs, verdict_fun: vf(beh))
    assert edges == [{"A", "B"}]
  end
end
