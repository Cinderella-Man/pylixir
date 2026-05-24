defmodule EvalTest do
  use ExUnit.Case, async: false

  # `no_examples: true` keeps these hermetic — no CPython tracer is
  # invoked; the harness just transpiles, compiles, runs the Elixir, and
  # compares its stdout to the dataset `expected`.
  describe "process/2 with mock corpus" do
    test "all-passing testcases produce :ok bucket" do
      samples = [
        %{
          id: "ok-sample",
          source: "print(\"hello\")\n",
          testcases: [%{stdin: "", expected: "hello"}]
        }
      ]

      acc =
        with_silent_io(fn ->
          Eval.process(samples, concurrency: 1, samples_per_bucket: 5, no_examples: true)
        end)

      assert acc.totals.processed == 1
      assert acc.totals.testcases_run == 1
      assert acc.totals.testcases_passed == 1

      assert Map.has_key?(acc.counts, :ok),
             "expected :ok bucket; got #{inspect(Map.keys(acc.counts))}"
    end

    test "worst-of: a mismatched testcase elevates the sample bucket to :output_mismatch" do
      # Same source, two testcases. Elixir prints "hello"; the second
      # testcase's `expected: "wrong"` triggers `:output_mismatch`
      # (Elixir ≠ expected). The first is `:ok`. Worst-of wins.
      samples = [
        %{
          id: "mixed",
          source: "print(\"hello\")\n",
          testcases: [
            %{stdin: "", expected: "hello"},
            %{stdin: "", expected: "wrong"}
          ]
        }
      ]

      acc =
        with_silent_io(fn ->
          Eval.process(samples, concurrency: 1, samples_per_bucket: 5, no_examples: true)
        end)

      assert acc.totals.processed == 1
      assert acc.totals.testcases_run == 2
      assert acc.totals.testcases_passed == 1

      buckets = Map.keys(acc.counts)

      assert Enum.any?(buckets, &match?({:output_mismatch, _}, &1)),
             "expected worst-of to lift the sample bucket to :output_mismatch; got #{inspect(buckets)}"

      refute Map.has_key?(acc.counts, :ok),
             "single-sample run should not also produce a :ok bucket entry"
    end

    test "empty corpus processes nothing" do
      acc = with_silent_io(fn -> Eval.process([], concurrency: 1) end)
      assert acc.totals.processed == 0
      assert acc.counts == %{}
    end
  end

  defp with_silent_io(fun) do
    {result, _io} = ExUnit.CaptureIO.with_io(fun)
    result
  end
end
