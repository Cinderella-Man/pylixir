defmodule EvalTest do
  use ExUnit.Case, async: false

  @fixtures_dir Path.expand("../../../test/fixtures/python", __DIR__)

  describe "process/2 against golden fixtures" do
    test "every fixture in test/fixtures/python lands in :ok or a categorized failure bucket" do
      samples =
        @fixtures_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".py"))
        |> Enum.sort()
        |> Enum.map(fn name ->
          %{
            "id" => name,
            "source" => File.read!(Path.join(@fixtures_dir, name))
          }
        end)

      acc = Eval.process(samples, concurrency: 2, samples_per_bucket: 5)

      assert acc.totals.processed == length(samples)
      assert acc.totals.skipped == 0
      assert acc.totals.transpiled > 0

      assert Map.has_key?(acc.counts, :ok),
             "expected at least one fixture to transpile + compile cleanly; got buckets: " <>
               inspect(Map.keys(acc.counts))
    end
  end

  describe "process/2 with skip lines" do
    test "skip envelopes increment the skipped counter without classifying" do
      lines = [
        %{"_skip" => "no python", "id" => "0"},
        %{"_skip" => "again", "id" => "1"}
      ]

      acc = Eval.process(lines, concurrency: 1)

      assert acc.totals == %{processed: 0, skipped: 2, transpiled: 0}
      assert acc.counts == %{}
    end
  end
end
