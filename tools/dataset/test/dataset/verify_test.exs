defmodule Dataset.VerifyTest do
  # Runs real python3.14; sandbox disabled. async: false (env var + named cache).
  use ExUnit.Case, async: false

  alias Dataset.{Verify, PythonCache}

  setup_all do
    path = Path.join(System.tmp_dir!(), "verify_cache_#{System.unique_integer([:positive])}.jsonl")
    {:ok, _} = PythonCache.ensure_started(path: path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  setup do
    prev = System.get_env("PYLIXIR_DATASET_SANDBOX")
    System.put_env("PYLIXIR_DATASET_SANDBOX", "")

    on_exit(fn ->
      if prev, do: System.put_env("PYLIXIR_DATASET_SANDBOX", prev),
        else: System.delete_env("PYLIXIR_DATASET_SANDBOX")
    end)

    :ok
  end

  defp tc(stdin, expecteds),
    do: %{stdin: stdin, expecteds: expecteds, n_stored_outputs: length(expecteds)}

  @fast [timeout_ms: 5000]

  test "deterministic program matching stored expected → kept" do
    src = "print(sorted(set([3, 1, 2])))"
    assert {:keep, "[1, 2, 3]"} = Verify.verify_testcase(src, tc("", ["[1, 2, 3]"]), @fast)
  end

  test "set-iteration-order program → nondeterministic → dropped" do
    src = "print(set(str(i) for i in range(20)))"
    assert {:drop, :nondeterministic} = Verify.verify_testcase(src, tc("", ["whatever"]), @fast)
  end

  test "unseeded random → nondeterministic → dropped" do
    src = "import random; print(random.random())"
    assert {:rejected, :nondeterministic} = Verify.verdict(src, "", @fast)
  end

  test "seeded random → reproducible (kept as verifiable)" do
    src = "import random; random.seed(42); print(random.random())"
    assert {:reproducible, _canonical} = Verify.verdict(src, "", @fast)
  end

  test "deterministic output matching NO stored expected → dropped (mismatch)" do
    assert {:drop, :mismatch} = Verify.verify_testcase(~s|print("X")|, tc("", ["Y"]), @fast)
  end

  test "matches one of several conflicting stored outputs → kept" do
    assert {:keep, "B"} = Verify.verify_testcase(~s|print("B")|, tc("", ["A", "B", "C"]), @fast)
  end

  test "runaway output exceeding the relative cap → dropped" do
    src = ~s|print("x" * 10_000_000)|
    # stored expected is tiny → cap ≈ 1 MB → runaway exceeds it
    assert {:drop, :output_exceeded} = Verify.verify_testcase(src, tc("", ["x"]), @fast)
  end

  test "verdict is cached per (source, stdin) — second call hits ETS" do
    src = ~s|print("cached")|
    stdin = "z"
    assert PythonCache.lookup(PythonCache.key(src, stdin)) == :miss
    assert {:reproducible, "cached"} = Verify.verdict(src, stdin, @fast)
    assert {:hit, %{"status" => "reproducible"}} = PythonCache.lookup(PythonCache.key(src, stdin))
  end

  test "verify_solution returns kept shippable testcases with canonical expected" do
    solution = %{sha: "h1", source: ~s|import sys; print(sys.stdin.read().strip().upper())|}

    testcases = [
      tc("hi", ["HI"]),
      # this one's stored expected won't match → dropped
      tc("yo", ["nope"])
    ]

    kept = Verify.verify_solution(solution, testcases, @fast)
    assert kept == [%{stdin: "hi", expected: "HI", n_stored_outputs: 1}]
  end
end
