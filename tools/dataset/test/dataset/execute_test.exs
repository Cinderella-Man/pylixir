defmodule Dataset.ExecuteTest do
  # Runs real python3.14. Sandbox disabled (empty prefix) — no untrusted
  # code here, and we don't want netns setup in the unit suite.
  use ExUnit.Case, async: false

  alias Dataset.Execute

  setup do
    prev = System.get_env("PYLIXIR_DATASET_SANDBOX")
    System.put_env("PYLIXIR_DATASET_SANDBOX", "")

    on_exit(fn ->
      if prev, do: System.put_env("PYLIXIR_DATASET_SANDBOX", prev),
        else: System.delete_env("PYLIXIR_DATASET_SANDBOX")
    end)

    :ok
  end

  test "runs a trivial program" do
    assert {:ok, "hi\n"} = Execute.run_python("print('hi')", timeout_ms: 5000)
  end

  test "feeds stdin" do
    assert {:ok, "HELLO\n"} =
             Execute.run_python("import sys; print(sys.stdin.read().strip().upper())",
               stdin: "hello",
               timeout_ms: 5000
             )
  end

  test "reports a non-zero exit with combined output" do
    assert {:exit, 3, _out} =
             Execute.run_python("import sys; sys.exit(3)", timeout_ms: 5000)
  end

  test "enforces the wall-clock timeout" do
    assert :timeout =
             Execute.run_python("import time; time.sleep(5)", timeout_ms: 300)
  end

  test "relative output cap aborts a runaway program" do
    assert :output_exceeded =
             Execute.run_python("print('x' * 10_000_000)",
               timeout_ms: 5000,
               output_cap: 1000
             )
  end

  test "PYTHONHASHSEED is unset → hash-order varies across runs (seed not pinned)" do
    # set iteration order depends on the per-process hash seed; with the
    # seed left random, repeated runs produce differing output.
    src = "print(set(str(i) for i in range(20)))"

    outputs =
      for _ <- 1..12 do
        {:ok, out} = Execute.run_python(src, timeout_ms: 5000)
        out
      end

    assert outputs |> Enum.uniq() |> length() > 1,
           "expected hash-order to vary across runs; got identical output (seed pinned?)"
  end
end
