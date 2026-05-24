# Measure the behavioral-dedup impact on the existing out/v1.
# Run: mix run validate_behavioral.exs
require Explorer.DataFrame, as: DF
alias Dataset.{Behavioral, Dedup, PythonCache, SourceNorm}

System.put_env("PYLIXIR_DATASET_SANDBOX", "")
{:ok, _} = PythonCache.ensure_started(path: Path.expand("cache/verify.jsonl", File.cwd!()))

df = DF.from_parquet!("out/v1/data.parquet")
ids = DF.pull(df, "id") |> Explorer.Series.to_list()
src = DF.pull(df, "source") |> Explorer.Series.to_list()
sha = DF.pull(df, "solution_sha256") |> Explorer.Series.to_list()
tcs = DF.pull(df, "testcases") |> Explorer.Series.to_list()
meta = DF.pull(df, "meta") |> Explorer.Series.to_list()

rows =
  [ids, src, sha, tcs, meta]
  |> Enum.zip()
  |> Enum.map(fn {id, source, s, tc_json, meta_json} ->
    testcases =
      Jason.decode!(tc_json)
      |> Enum.map(fn t -> %{stdin: t["stdin"], expected: t["expected"], n_stored_outputs: t["n_stored_outputs"]} end)

    m = Jason.decode!(meta_json)
    %{id: id, source: source, solution_sha256: s, testcases: testcases,
      member_qids: m["member_qids"] || [], alternate_solution_shas: m["alternate_solution_shas"] || []}
  end)

IO.puts("rows: #{length(rows)}")
fps = Enum.map(rows, &Dedup.fingerprint/1)
norm = SourceNorm.hashes(Enum.map(rows, &{&1.id, &1.source}), mode: "struct")

pairs = Dedup.candidates(fps, norm_hashes: norm)
IO.puts("candidate pairs: #{length(pairs)}")

rows_by_id = Map.new(rows, fn r -> {r.id, %{source: r.source, testcases: r.testcases}} end)
edges = Behavioral.edges(rows_by_id, pairs, run_count: 2, timeout_ms: 8000)
IO.puts("behavioral-equivalent pairs: #{length(edges)}")

{keep0, _} = Dedup.cluster(fps, min_shared: 2, norm_hashes: norm)
{keep1, ov} = Dedup.cluster(fps, min_shared: 2, norm_hashes: norm, extra_edges: edges)
IO.puts("kept without behavioral: #{MapSet.size(keep0)}")
IO.puts("kept WITH behavioral:    #{MapSet.size(keep1)}  (#{map_size(ov)} clusters merged)")
