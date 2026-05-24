defmodule Eval.Corpus do
  @moduledoc """
  Streams the curated evaluation corpus from the single `data.parquet`
  (see `Eval.Dataset`).

  Every row is already a complete `(solution, testcases)` sample — the
  dataset is pre-joined, deduped, and verified, so there is nothing to
  join or filter here. `build/1` opens the parquet once (an off-heap
  Polars frame) and returns a **lazy** stream that slices the frame in
  batches, JSON-decoding the `testcases` column one batch at a time so
  resident BEAM memory stays bounded and `--limit N` runs touch only the
  first batch.

  Each yielded sample:

      %{
        id: "seed_14661--636e9430",
        source: "n = int(input())\\nprint(n * 2)\\n",
        testcases: [%{stdin: "3\\n", expected: "6"}, ...]
      }

  `testcases` is stored as a JSON string column
  (`[{"stdin","expected","n_stored_outputs"}]`); we keep only
  `stdin`/`expected` (the harness evaluates the stdin/stdout path).
  """

  alias Eval.Dataset
  require Explorer.DataFrame, as: DF

  @type testcase :: %{stdin: String.t(), expected: String.t()}
  @type sample :: %{id: String.t(), source: String.t(), testcases: [testcase()]}

  @default_batch 500

  @doc """
  Open the curated parquet and return a lazy `Stream` of samples.

  ## Options
    * `:parquet_path` — override the parquet location. Defaults to
      `Eval.Dataset.ensure_parquet!/0` (download-if-absent).
    * `:batch` — rows decoded per pull (default `#{@default_batch}`).
  """
  @spec build(keyword()) :: Enumerable.t()
  def build(opts \\ []) do
    # Log only on the real run (no explicit `:parquet_path` → tests stay quiet).
    {path, log?} =
      case Keyword.fetch(opts, :parquet_path) do
        {:ok, p} -> {p, false}
        :error -> {Dataset.ensure_parquet!(), true}
      end

    batch = Keyword.get(opts, :batch, @default_batch)

    if log?, do: IO.puts("[corpus] reading #{Path.relative_to_cwd(path)} …")
    df = DF.from_parquet!(path, columns: ["id", "source", "testcases"])
    total = DF.n_rows(df)
    if log?, do: IO.puts("[corpus] #{total} rows loaded; streaming (batch #{batch})")

    Stream.resource(
      fn -> 0 end,
      fn offset ->
        if offset >= total do
          {:halt, offset}
        else
          {decode_batch(df, offset, min(batch, total - offset)), offset + batch}
        end
      end,
      fn _ -> :ok end
    )
  end

  # --- Internals -------------------------------------------------------

  defp decode_batch(df, offset, length) do
    slice = DF.slice(df, offset, length)

    ids = slice |> DF.pull("id") |> Explorer.Series.to_list()
    sources = slice |> DF.pull("source") |> Explorer.Series.to_list()
    testcases = slice |> DF.pull("testcases") |> Explorer.Series.to_list()

    [ids, sources, testcases]
    |> Enum.zip()
    |> Enum.map(fn {id, source, tc_json} ->
      %{id: id, source: source, testcases: decode_testcases(tc_json)}
    end)
  end

  defp decode_testcases(json) do
    json
    |> Jason.decode!()
    |> Enum.map(fn %{"stdin" => stdin, "expected" => expected} ->
      %{stdin: stdin, expected: expected}
    end)
  end
end
