defmodule Dataset.BehavioralIntegrationTest do
  # Real python3.14 via Verify/Execute; sandbox off; named cache → async: false.
  use ExUnit.Case, async: false

  alias Dataset.{Behavioral, PythonCache}

  setup do
    prev = System.get_env("PYLIXIR_DATASET_SANDBOX")
    System.put_env("PYLIXIR_DATASET_SANDBOX", "")
    path = Path.join(System.tmp_dir!(), "beh_#{System.unique_integer([:positive])}.jsonl")
    {:ok, _} = PythonCache.ensure_started(path: path)

    on_exit(fn ->
      if prev, do: System.put_env("PYLIXIR_DATASET_SANDBOX", prev),
        else: System.delete_env("PYLIXIR_DATASET_SANDBOX")

      File.rm(path)
    end)

    :ok
  end

  defp row(source, tcs),
    do: %{source: source, testcases: Enum.map(tcs, fn {s, e} -> %{stdin: s, expected: e} end)}

  test "two different solutions to the same problem, disjoint testcases, are equivalent" do
    # both compute n+1; expecteds are the normalized canonical (no trailing \n)
    a = row("print(int(input()) + 1)", [{"5\n", "6"}, {"41\n", "42"}])
    b = row("n = int(input())\nprint(n + 1)", [{"99\n", "100"}, {"0\n", "1"}])

    assert Behavioral.equivalent?(a, b, run_count: 2, timeout_ms: 5000)
  end

  test "solutions to different problems are not equivalent" do
    a = row("print(int(input()) + 1)", [{"5\n", "6"}])
    b = row("print(int(input()) * 2)", [{"5\n", "10"}])

    refute Behavioral.equivalent?(a, b, run_count: 2, timeout_ms: 5000)
  end
end
