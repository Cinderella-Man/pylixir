defmodule Eval.BucketTest do
  use ExUnit.Case, async: true

  alias Eval.Bucket

  @sample %{id: "0", source: "x = 1"}

  describe "transpile failures" do
    test "classifies UnsupportedNodeError by node_type" do
      exception = %Pylixir.UnsupportedNodeError{
        node_type: "ClassDef",
        hint: "classes not supported",
        lineno: 3,
        col_offset: 0,
        message: "ClassDef at line 3, col 0: classes not supported"
      }

      assert {{:unsupported, "ClassDef"}, meta} =
               Bucket.classify(@sample, {:transpile_raised, exception})

      assert meta.node_type == "ClassDef"
      assert meta.hint == "classes not supported"
      assert meta.lineno == 3
    end

    test "classifies PythonParseError as :parse_error" do
      exception = %Pylixir.PythonParseError{
        message: "invalid syntax",
        lineno: 1,
        col_offset: 0,
        text: "def "
      }

      assert {:parse_error, meta} = Bucket.classify(@sample, {:transpile_raised, exception})
      assert meta.message == "invalid syntax"
    end
  end

  describe "compile failures" do
    test "classifies {:compile_raised, _} as {:compile_error, _}" do
      exception = %RuntimeError{message: "compile blew up"}

      assert {{:compile_error, fingerprint}, meta} =
               Bucket.classify(@sample, {:transpile_ok, "src", {:compile_raised, exception}})

      assert is_binary(fingerprint)
      assert meta.exception =~ "RuntimeError"
      assert meta.message =~ "compile blew up"
    end
  end

  describe "executed_testcases — worst-of aggregation (2-way)" do
    test "all-:ok per-testcases produce :ok bucket" do
      per_tc = [{:ok, %{}}, {:ok, %{}}]

      assert {:ok, meta} = classify_executed(per_tc)
      assert meta.per_testcase == per_tc
      assert meta.elixir_source == "src"
    end

    test "all-:ok_empty per-testcases produce :ok_empty_output bucket" do
      per_tc = [{:ok_empty, %{}}, {:ok_empty, %{}}]
      assert {:ok_empty_output, _} = classify_executed(per_tc)
    end

    test "mixed :ok + :ok_empty falls back to :ok" do
      per_tc = [{:ok, %{}}, {:ok_empty, %{}}]
      assert {:ok, _} = classify_executed(per_tc)
    end

    test ":elixir_runtime_error beats everything below it" do
      per_tc = [
        {:ok, %{}},
        {:output_mismatch, "fp2", %{}},
        {:elixir_runtime_error, RuntimeError, %{message: "boom"}}
      ]

      assert {{:elixir_runtime_error, RuntimeError}, meta} = classify_executed(per_tc)
      assert meta.failing_index == 2
      assert meta.message == "boom"
    end

    test ":elixir_timeout beats :output_mismatch" do
      per_tc = [
        {:output_mismatch, "fp", %{}},
        {:elixir_timeout, %{}}
      ]

      assert {:elixir_timeout, meta} = classify_executed(per_tc)
      assert meta.failing_index == 1
    end

    test ":output_mismatch beats :ok" do
      per_tc = [
        {:ok, %{}},
        {:output_mismatch, "mm_fp", %{diff_summary: "boom", expected: "1\n", elixir_stdout: "2\n"}}
      ]

      assert {{:output_mismatch, "mm_fp"}, meta} = classify_executed(per_tc)
      assert meta.diff_summary == "boom"
      assert meta.failing_index == 1
    end
  end

  describe "slug/1" do
    test "produces filesystem-safe strings" do
      assert Bucket.slug({:unsupported, "ClassDef"}) == "unsupported--ClassDef"
      assert Bucket.slug(:parse_error) == "parse_error"
      assert Bucket.slug({:compile_error, "weird /msg with spaces"}) =~ "compile_error--"
      assert Bucket.slug({:output_mismatch, "foo bar"}) =~ "output_mismatch--foo_bar"
      assert Bucket.slug({:elixir_runtime_error, RuntimeError}) =~ "elixir_runtime_error--"
      assert Bucket.slug(:elixir_timeout) == "elixir_timeout"
    end
  end

  defp classify_executed(per_tc) do
    Bucket.classify(@sample, {:transpile_ok, "src", {:executed_testcases, [], per_tc}})
  end
end
