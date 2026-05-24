defmodule Eval.CorpusTest do
  use ExUnit.Case, async: true

  alias Eval.Corpus
  require Explorer.DataFrame, as: DF

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "corpus_test_#{System.unique_integer([:positive])}.parquet"
      )

    on_exit(fn -> File.rm(tmp) end)
    {:ok, tmp: tmp}
  end

  # The curated parquet stores `testcases` as a JSON string column
  # ([{stdin, expected, n_stored_outputs}]); build that shape so the test
  # exercises the real read + decode path.
  defp write_parquet(path, rows) do
    DF.new(
      id: Enum.map(rows, & &1.id),
      source: Enum.map(rows, & &1.source),
      testcases: Enum.map(rows, fn r -> Jason.encode!(r.testcases) end)
    )
    |> DF.to_parquet!(path)
  end

  test "streams %{id, source, testcases}, decoding the testcases JSON column", %{tmp: tmp} do
    write_parquet(tmp, [
      %{
        id: "seed_1--abcd1234",
        source: "print(input())",
        testcases: [%{"stdin" => "x\n", "expected" => "x", "n_stored_outputs" => 1}]
      },
      %{
        id: "seed_2--ef015678",
        source: "print(2)",
        testcases: [
          %{"stdin" => "", "expected" => "2", "n_stored_outputs" => 1},
          %{"stdin" => "1\n", "expected" => "2", "n_stored_outputs" => 1}
        ]
      }
    ])

    samples = Corpus.build(parquet_path: tmp) |> Enum.to_list()

    assert length(samples) == 2
    [a, b] = samples

    assert a.id == "seed_1--abcd1234"
    assert a.source == "print(input())"
    assert a.testcases == [%{stdin: "x\n", expected: "x"}]

    assert length(b.testcases) == 2
    assert Enum.all?(b.testcases, &match?(%{stdin: _, expected: _}, &1))
    # Only stdin/expected are kept (n_stored_outputs dropped).
    assert Map.keys(hd(b.testcases)) |> Enum.sort() == [:expected, :stdin]
  end

  test "is lazy — Enum.take pulls only the leading batch", %{tmp: tmp} do
    rows =
      for i <- 1..5 do
        %{
          id: "seed_#{i}",
          source: "print(#{i})",
          testcases: [%{"stdin" => "", "expected" => "#{i}", "n_stored_outputs" => 1}]
        }
      end

    write_parquet(tmp, rows)

    first2 =
      Corpus.build(parquet_path: tmp, batch: 2)
      |> Enum.take(2)
      |> Enum.map(& &1.id)

    assert first2 == ["seed_1", "seed_2"]
  end

  test "an empty parquet yields an empty stream", %{tmp: tmp} do
    DF.new(id: [], source: [], testcases: []) |> DF.to_parquet!(tmp)
    assert Corpus.build(parquet_path: tmp) |> Enum.to_list() == []
  end
end
