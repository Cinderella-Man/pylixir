defmodule EvalTest do
  use ExUnit.Case, async: false

  describe "process/2 with mock corpus" do
    test "all-passing testcases produce :ok bucket" do
      samples = [
        %{
          id: "ok-sample",
          source: "print(\"hello\")\n",
          testcases: [%{stdin: "", expected: "hello\n"}]
        }
      ]

      acc =
        with_silent_io(fn ->
          Eval.process(samples, concurrency: 1, samples_per_bucket: 5)
        end)

      assert acc.totals.processed == 1
      assert acc.totals.testcases_run == 1
      assert acc.totals.testcases_passed == 1
      assert Map.has_key?(acc.counts, :ok),
             "expected :ok bucket; got #{inspect(Map.keys(acc.counts))}"
    end

    test "worst-of: one mismatched testcase elevates the sample bucket" do
      # Same source, two testcases. Python output is always "hello\n",
      # so the second testcase's `expected: "wrong\n"` triggers the
      # `:python_disagrees_expected` per-tc classification (py != expected,
      # ex == py). The first testcase is `:ok`. The sample bucket should
      # be the worst-of — `:python_disagrees_expected` beats `:ok`.
      samples = [
        %{
          id: "mixed",
          source: "print(\"hello\")\n",
          testcases: [
            %{stdin: "", expected: "hello\n"},
            %{stdin: "", expected: "wrong\n"}
          ]
        }
      ]

      acc =
        with_silent_io(fn ->
          Eval.process(samples, concurrency: 1, samples_per_bucket: 5)
        end)

      assert acc.totals.processed == 1
      assert acc.totals.testcases_run == 2
      assert acc.totals.testcases_passed == 1

      buckets = Map.keys(acc.counts)

      assert Enum.any?(buckets, &match?({:python_disagrees_expected, _}, &1)),
             "expected worst-of to lift sample bucket to :python_disagrees_expected; got #{inspect(buckets)}"

      refute Map.has_key?(acc.counts, :ok),
             "single-sample run should not also produce a :ok bucket entry"
    end

    test "corpus_stats threads testcase_shard_missing into totals" do
      acc =
        with_silent_io(fn ->
          Eval.process([], concurrency: 1, corpus_stats: %{testcase_shard_missing: 42})
        end)

      assert acc.totals.testcase_shard_missing == 42
      assert acc.totals.processed == 0
    end
  end

  # `Eval.process` prints `[python_cache]` / progress / etc. via
  # `IO.puts`. Tests don't care about those — swallow them so the test
  # runner output stays focused on assertion failures.
  defp with_silent_io(fun) do
    {result, _io} = ExUnit.CaptureIO.with_io(fun)
    result
  end
end
