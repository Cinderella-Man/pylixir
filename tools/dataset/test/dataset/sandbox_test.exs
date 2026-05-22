defmodule Dataset.SandboxTest do
  # async: false — these tests mutate the PYLIXIR_DATASET_SANDBOX env var.
  use ExUnit.Case, async: false

  alias Dataset.Sandbox

  setup do
    prev = System.get_env("PYLIXIR_DATASET_SANDBOX")

    on_exit(fn ->
      if prev, do: System.put_env("PYLIXIR_DATASET_SANDBOX", prev),
        else: System.delete_env("PYLIXIR_DATASET_SANDBOX")
    end)

    :ok
  end

  test "default prefix enters userns first, then netns, then prlimit" do
    System.delete_env("PYLIXIR_DATASET_SANDBOX")
    pfx = Sandbox.prefix()
    assert pfx =~ "unshare --user --map-root-user --net --"
    assert pfx =~ ~r/prlimit --as=\d+ --cpu=\d+ --/
    assert Sandbox.enabled?()
  end

  test "empty env disables the wrapper" do
    System.put_env("PYLIXIR_DATASET_SANDBOX", "")
    refute Sandbox.enabled?()
    assert Sandbox.wrap("python3.14 f.py") == "python3.14 f.py"
  end

  test "wrap prepends a non-empty prefix" do
    System.put_env("PYLIXIR_DATASET_SANDBOX", "myprefix --")
    assert Sandbox.wrap("python3.14 f.py") == "myprefix -- python3.14 f.py"
  end

  test "self_test! passes with the real default sandbox (network isolated)" do
    System.delete_env("PYLIXIR_DATASET_SANDBOX")
    assert Sandbox.self_test!() == :ok
  end

  test "self_test! fails closed when the prefix command is broken" do
    # /bin/false exits non-zero before python ever runs.
    System.put_env("PYLIXIR_DATASET_SANDBOX", "false")

    assert_raise RuntimeError, ~r/fail-closed/, fn -> Sandbox.self_test!() end
  end
end
