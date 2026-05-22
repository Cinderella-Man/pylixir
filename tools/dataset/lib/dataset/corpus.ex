defmodule Dataset.Corpus do
  @moduledoc """
  Joined, deduped `(solution, testcases)` corpus built from the
  `seed_sft` + `seed_testcase` configs of `microsoft/rStar-Coder`.

  Build phases (cold path):

    1. Scan every `seed_sft` shard, projecting `question_id, code,
       is_passed`. Keep only `is_passed=true` rows. Dedup by
       `(qid, sha256(source))`.
    2. Scan up to `--testcase-shards K` `seed_testcase` shards with a
       Polars filter pushdown restricting to qids present in (1). For
       each surviving row, append `%{stdin, expected}` to that qid's
       testcase list.
    3. Serialise the two maps plus a small header (shards_loaded,
       parquet mtimes) to `cache/corpus_v1.term.gz`.

  Warm path: if the cache file exists, its header's `shards_loaded`
  matches the current `K`, and no underlying parquet file has a newer
  mtime than the cache, the maps are restored directly.

  `build/1` returns `{stream, stats}`:

    * `stream` is a lazy `Stream.t/0` yielding
      `%{id: "<qid>--<sha8>", source: String.t(), testcases: [%{stdin, expected}]}`.
    * `stats` is a map with `:testcase_shard_missing`,
      `:total_solutions`, `:total_qids_with_solutions`,
      `:total_qids_with_testcases`.

  `grouped/1` returns the underlying `{solutions_by_qid,
  testcases_by_qid, stats}` — the curator regroups these by merge-group
  (`Dataset.Candidates`) rather than consuming the per-solution stream.

  Copied from `Eval.Corpus` (pure join/dedup, no pylixir); namespace
  renamed, plus the additive `grouped/1` accessor for the curator.
  """

  alias Dataset.Dataset
  require Explorer.DataFrame, as: DF
  require Logger

  @cache_filename "corpus_v1.term.gz"
  @cache_version 1

  @type solution :: %{sha: String.t(), source: String.t()}
  @type testcase :: %{stdin: String.t(), expected: String.t()}
  @type sample :: %{
          id: String.t(),
          source: String.t(),
          testcases: [testcase()]
        }
  @type stats :: %{
          testcase_shard_missing: non_neg_integer(),
          total_solutions: non_neg_integer(),
          total_qids_with_solutions: non_neg_integer(),
          total_qids_with_testcases: non_neg_integer()
        }

  @doc """
  Build (or restore) the corpus and return `{stream, stats}`.

  ## Options

    * `:testcase_shards` — number of `seed_testcase` shards to load
      (default 1). Each shard adds ~1.5 GB to the resident
      `testcases_by_qid` map.
    * `:dataset_module` — module implementing the `shard_count/1`,
      `shard_path/2`, `read_sft_shard/2`, `read_testcase_shard/3`
      surface. Defaults to `Dataset.Dataset`. Tests pass a fake.
    * `:cache_path` — override the on-disk cache path. Defaults to
      `cache/corpus_v1.term.gz` under `tools/dataset/`.
  """
  @spec build(keyword()) :: {Enumerable.t(), stats()}
  def build(opts \\ []) do
    {solutions_by_qid, testcases_by_qid, stats} = grouped(opts)
    stream = stream_samples(solutions_by_qid, testcases_by_qid)
    {stream, stats}
  end

  @doc """
  Build (or restore) the corpus and return the grouped maps plus stats:
  `{solutions_by_qid, testcases_by_qid, stats}`. Same options as
  `build/1`. Used by `Dataset.Candidates` to regroup by merge-group.
  """
  @spec grouped(keyword()) :: {map(), map(), stats()}
  def grouped(opts \\ []) do
    k = Keyword.get(opts, :testcase_shards, 1)
    dataset = Keyword.get(opts, :dataset_module, Dataset)
    cache_path = Keyword.get(opts, :cache_path, default_cache_path())

    {solutions_by_qid, testcases_by_qid} =
      case load_cache(k, cache_path) do
        {:hit, payload} ->
          Logger.info("[corpus] warm cache hit (#{cache_path})")
          {payload.solutions_by_qid, payload.testcases_by_qid}

        :miss ->
          Logger.info("[corpus] cold build (testcase_shards=#{k})")
          rebuild_and_cache(k, dataset, cache_path)
      end

    stats = compute_stats(solutions_by_qid, testcases_by_qid)
    {solutions_by_qid, testcases_by_qid, stats}
  end

  @doc """
  On-disk path of the corpus cache file (default location).
  """
  @spec cache_path() :: String.t()
  def cache_path, do: default_cache_path()

  defp default_cache_path do
    Path.join(Path.expand("../../cache", __DIR__), @cache_filename)
  end

  # --- Cold build ------------------------------------------------------

  defp rebuild_and_cache(k, dataset, cache_path) do
    sft_total = dataset.shard_count(:seed_sft)

    solutions_by_qid =
      Enum.reduce(0..(sft_total - 1), %{}, fn idx, acc ->
        Logger.info("[corpus] seed_sft shard #{idx + 1}/#{sft_total}")
        df = dataset.read_sft_shard(idx, ["question_id", "code", "is_passed"])
        accumulate_solutions(df, acc)
      end)
      |> materialise_solutions()

    qid_filter = Map.keys(solutions_by_qid)

    testcases_by_qid =
      Enum.reduce(0..(k - 1), %{}, fn idx, acc ->
        Logger.info("[corpus] seed_testcase shard #{idx + 1}/#{k}")

        df =
          dataset.read_testcase_shard(idx, qid_filter, [
            "question_id",
            "inputs",
            "outputs"
          ])

        accumulate_testcases(df, acc)
      end)

    write_cache(k, solutions_by_qid, testcases_by_qid, dataset, cache_path)
    {solutions_by_qid, testcases_by_qid}
  end

  # Accumulator value: %{qid => MapSet.t({sha, source})}
  defp accumulate_solutions(df, acc) do
    qids = df |> DF.pull("question_id") |> Explorer.Series.to_list()
    codes = df |> DF.pull("code") |> Explorer.Series.to_list()
    passed = df |> DF.pull("is_passed") |> Explorer.Series.to_list()

    [qids, codes, passed]
    |> Enum.zip()
    |> Enum.reduce(acc, fn
      {nil, _code, _is_passed}, acc ->
        acc

      {_qid, nil, _is_passed}, acc ->
        acc

      {_qid, _code, true_value}, acc when true_value in [false, nil] ->
        acc

      {qid, code, _is_passed}, acc ->
        sha = sha256(code)
        entry = {sha, code}
        Map.update(acc, qid, MapSet.new([entry]), &MapSet.put(&1, entry))
    end)
  end

  defp materialise_solutions(mapset_acc) do
    Map.new(mapset_acc, fn {qid, mapset} ->
      entries =
        mapset
        |> Enum.map(fn {sha, source} -> %{sha: sha, source: source} end)
        |> Enum.sort_by(& &1.sha)

      {qid, entries}
    end)
  end

  # `inputs` and `outputs` are *JSON-encoded lists of strings* — one
  # element per testcase. The dataset packs all of a qid's testcases
  # into a single row (matched by index across the two lists). Decode
  # both, zip into `%{stdin, expected}` pairs, and append to the qid's
  # bucket. Rows whose JSON doesn't decode to matched string lists
  # (e.g. function-call-style testcases) are dropped.
  defp accumulate_testcases(df, acc) do
    qids = df |> DF.pull("question_id") |> Explorer.Series.to_list()
    inputs = df |> DF.pull("inputs") |> Explorer.Series.to_list()
    outputs = df |> DF.pull("outputs") |> Explorer.Series.to_list()

    [qids, inputs, outputs]
    |> Enum.zip()
    |> Enum.reduce(acc, fn
      {nil, _, _}, acc ->
        acc

      {_qid, nil, _}, acc ->
        acc

      {_qid, _, nil}, acc ->
        acc

      {qid, inputs_json, outputs_json}, acc ->
        case parse_testcases(inputs_json, outputs_json) do
          [] -> acc
          tcs -> Map.update(acc, qid, tcs, &(tcs ++ &1))
        end
    end)
  end

  defp parse_testcases(inputs_json, outputs_json) do
    with {:ok, stdins} <- Jason.decode(inputs_json),
         {:ok, expecteds} <- Jason.decode(outputs_json),
         true <- is_list(stdins) and is_list(expecteds),
         true <- length(stdins) == length(expecteds) do
      stdins
      |> Enum.zip(expecteds)
      |> Enum.flat_map(fn
        {stdin, expected} when is_binary(stdin) and is_binary(expected) ->
          [%{stdin: stdin, expected: expected}]

        _ ->
          # Non-string entries indicate a function-call-style testcase
          # (args list / dict). Skip — the harness only evaluates the
          # stdin/stdout path.
          []
      end)
    else
      _ -> []
    end
  end

  # --- Cache I/O -------------------------------------------------------

  defp load_cache(k, path) do
    with true <- File.exists?(path),
         {:ok, binary} <- File.read(path),
         {:ok, payload} <- safe_decode(binary),
         %{
           version: @cache_version,
           shards_loaded: ^k,
           parquet_mtimes: cached_mtimes,
           solutions_by_qid: _,
           testcases_by_qid: _
         } <- payload,
         true <- mtimes_still_valid?(cached_mtimes, path) do
      {:hit, payload}
    else
      _ -> :miss
    end
  end

  defp safe_decode(binary) do
    try do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  defp mtimes_still_valid?(cached_mtimes, cache_path) do
    cache_mtime = mtime_unix(cache_path)

    Enum.all?(cached_mtimes, fn {parquet_path, recorded_mtime} ->
      case mtime_unix(parquet_path) do
        nil -> false
        current -> current == recorded_mtime and current <= cache_mtime
      end
    end)
  end

  defp write_cache(k, solutions_by_qid, testcases_by_qid, dataset, path) do
    payload = %{
      version: @cache_version,
      shards_loaded: k,
      parquet_mtimes: collect_parquet_mtimes(k, dataset),
      solutions_by_qid: solutions_by_qid,
      testcases_by_qid: testcases_by_qid
    }

    partial = path <> ".partial"
    File.mkdir_p!(Path.dirname(path))

    binary = :erlang.term_to_binary(payload, [:compressed])
    File.write!(partial, binary)
    File.rename!(partial, path)

    Logger.info("[corpus] wrote #{path} (#{format_bytes(byte_size(binary))})")
  end

  defp collect_parquet_mtimes(k, dataset) do
    sft_total = dataset.shard_count(:seed_sft)

    sft_mtimes =
      for idx <- 0..(sft_total - 1), into: %{} do
        path = dataset.shard_path(:seed_sft, idx)
        {path, mtime_unix(path)}
      end

    tc_mtimes =
      for idx <- 0..(k - 1), into: %{} do
        path = dataset.shard_path(:seed_testcase, idx)
        {path, mtime_unix(path)}
      end

    Map.merge(sft_mtimes, tc_mtimes)
  end

  defp mtime_unix(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      {:error, _} -> nil
    end
  end

  # --- Output stream ---------------------------------------------------

  defp stream_samples(solutions_by_qid, testcases_by_qid) do
    solutions_by_qid
    |> Map.keys()
    |> Enum.sort()
    |> Stream.flat_map(fn qid ->
      case Map.fetch(testcases_by_qid, qid) do
        {:ok, tcs} ->
          Enum.map(Map.fetch!(solutions_by_qid, qid), fn %{sha: sha, source: source} ->
            %{
              id: "#{qid}--#{String.slice(sha, 0, 8)}",
              source: source,
              testcases: tcs
            }
          end)

        :error ->
          []
      end
    end)
  end

  defp compute_stats(solutions_by_qid, testcases_by_qid) do
    total_solutions =
      solutions_by_qid
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    missing =
      solutions_by_qid
      |> Enum.reject(fn {qid, _} -> Map.has_key?(testcases_by_qid, qid) end)
      |> Enum.map(fn {_qid, sols} -> length(sols) end)
      |> Enum.sum()

    %{
      testcase_shard_missing: missing,
      total_solutions: total_solutions,
      total_qids_with_solutions: map_size(solutions_by_qid),
      total_qids_with_testcases: map_size(testcases_by_qid)
    }
  end

  # --- Misc ------------------------------------------------------------

  defp sha256(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end

  defp format_bytes(n) when n >= 1_048_576,
    do: :erlang.float_to_binary(n / 1_048_576, decimals: 1) <> " MB"

  defp format_bytes(n) when n >= 1024,
    do: :erlang.float_to_binary(n / 1024, decimals: 1) <> " KB"

  defp format_bytes(n), do: "#{n} B"
end
