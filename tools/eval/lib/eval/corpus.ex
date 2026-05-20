defmodule Eval.Corpus do
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
  """

  alias Eval.Dataset
  require Explorer.DataFrame, as: DF

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
  """
  @spec build(keyword()) :: {Enumerable.t(), stats()}
  def build(opts \\ []) do
    k = Keyword.get(opts, :testcase_shards, 1)

    {solutions_by_qid, testcases_by_qid} =
      case load_cache(k) do
        {:hit, payload} ->
          IO.puts("[corpus] warm cache hit (#{cache_path()})")
          {payload.solutions_by_qid, payload.testcases_by_qid}

        :miss ->
          IO.puts("[corpus] cold build (testcase_shards=#{k})")
          rebuild_and_cache(k)
      end

    stats = compute_stats(solutions_by_qid, testcases_by_qid)
    stream = stream_samples(solutions_by_qid, testcases_by_qid)
    {stream, stats}
  end

  @doc """
  On-disk path of the corpus cache file.
  """
  @spec cache_path() :: String.t()
  def cache_path do
    Path.join(Path.expand("../../cache", __DIR__), @cache_filename)
  end

  # --- Cold build ------------------------------------------------------

  defp rebuild_and_cache(k) do
    sft_total = Dataset.shard_count(:seed_sft)

    solutions_by_qid =
      Enum.reduce(0..(sft_total - 1), %{}, fn idx, acc ->
        IO.puts("[corpus] seed_sft shard #{idx + 1}/#{sft_total}")
        df = Dataset.read_sft_shard(idx, ["question_id", "code", "is_passed"])
        accumulate_solutions(df, acc)
      end)
      |> materialise_solutions()

    qid_filter = Map.keys(solutions_by_qid)

    testcases_by_qid =
      Enum.reduce(0..(k - 1), %{}, fn idx, acc ->
        IO.puts("[corpus] seed_testcase shard #{idx + 1}/#{k}")

        df =
          Dataset.read_testcase_shard(idx, qid_filter, [
            "question_id",
            "inputs",
            "outputs"
          ])

        accumulate_testcases(df, acc)
      end)

    write_cache(k, solutions_by_qid, testcases_by_qid)
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
      {nil, _code, _is_passed}, acc -> acc
      {_qid, nil, _is_passed}, acc -> acc
      {_qid, _code, true_value}, acc when true_value in [false, nil] -> acc
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

  defp accumulate_testcases(df, acc) do
    qids = df |> DF.pull("question_id") |> Explorer.Series.to_list()
    inputs = df |> DF.pull("inputs") |> Explorer.Series.to_list()
    outputs = df |> DF.pull("outputs") |> Explorer.Series.to_list()

    [qids, inputs, outputs]
    |> Enum.zip()
    |> Enum.reduce(acc, fn
      {nil, _stdin, _expected}, acc -> acc
      {_qid, nil, _expected}, acc -> acc
      {_qid, _stdin, nil}, acc -> acc
      {qid, stdin, expected}, acc ->
        tc = %{stdin: stdin, expected: expected}
        Map.update(acc, qid, [tc], &[tc | &1])
    end)
  end

  # --- Cache I/O -------------------------------------------------------

  defp load_cache(k) do
    path = cache_path()

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

  defp write_cache(k, solutions_by_qid, testcases_by_qid) do
    payload = %{
      version: @cache_version,
      shards_loaded: k,
      parquet_mtimes: collect_parquet_mtimes(k),
      solutions_by_qid: solutions_by_qid,
      testcases_by_qid: testcases_by_qid
    }

    path = cache_path()
    partial = path <> ".partial"
    File.mkdir_p!(Path.dirname(path))

    binary = :erlang.term_to_binary(payload, [:compressed])
    File.write!(partial, binary)
    File.rename!(partial, path)

    IO.puts("[corpus] wrote #{path} (#{format_bytes(byte_size(binary))})")
  end

  defp collect_parquet_mtimes(k) do
    sft_total = Dataset.shard_count(:seed_sft)

    sft_mtimes =
      for idx <- 0..(sft_total - 1), into: %{} do
        path = Dataset.shard_path(:seed_sft, idx)
        {path, mtime_unix(path)}
      end

    tc_mtimes =
      for idx <- 0..(k - 1), into: %{} do
        path = Dataset.shard_path(:seed_testcase, idx)
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
