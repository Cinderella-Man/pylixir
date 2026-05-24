defmodule Dataset.Corpus do
  @moduledoc """
  Join + dedup of `microsoft/rStar-Coder`'s `seed_sft` (solutions) and
  `seed_testcase` (testcases) configs. Copied from `Eval.Corpus` (pure
  join/dedup, no pylixir); namespace renamed and split for the curator.

  The two halves are loaded independently so the build can fingerprint
  for merge-grouping *before* deciding which qids' testcases to
  materialise (see `Dataset.Build`):

    * `solutions/1` — scan **all** `seed_sft` shards → `solutions_by_qid`
      (`is_passed=true`, sha-deduped). Code is small; the whole set fits.
    * `testcases/2` — scan **all** `seed_testcase` shards, Polars-pushing
      the qid filter down (raw shards are ~5 GB each), → `testcases_by_qid`.
      Testcases are organized by shard, **not** by qid — a qid's
      testcases can be in any shard — so all shards are always read; the
      `qids` filter (and optional `:size_limit`) bound what's kept resident.

  `grouped/1` returns `{solutions_by_qid, testcases_by_qid, stats}` for
  *all* solution qids (convenience / tests). There is no on-disk corpus
  cache — for the full dataset the joined map is far too large to
  serialise, and resumability comes from the verdict cache instead.
  """

  alias Dataset.Dataset
  require Explorer.DataFrame, as: DF
  require Logger

  @type solution :: %{sha: String.t(), source: String.t()}
  @type testcase :: %{stdin: String.t(), expected: String.t()}
  @type stats :: %{
          testcase_shard_missing: non_neg_integer(),
          total_solutions: non_neg_integer(),
          total_qids_with_solutions: non_neg_integer(),
          total_qids_with_testcases: non_neg_integer()
        }

  @doc """
  Scan all `seed_sft` shards → `%{qid => [%{sha, source}]}`. Keeps
  `is_passed=true`, dedups solutions by `sha256(source)`.

  ## Options
    * `:dataset_module` — default `Dataset.Dataset` (tests pass a fake).
  """
  @spec solutions(keyword()) :: %{String.t() => [solution()]}
  def solutions(opts \\ []) do
    dataset = Keyword.get(opts, :dataset_module, Dataset)
    total = dataset.shard_count(:seed_sft)

    Enum.reduce(0..(total - 1), %{}, fn idx, acc ->
      Logger.info("[corpus] seed_sft shard #{idx + 1}/#{total}")
      df = dataset.read_sft_shard(idx, ["question_id", "code", "is_passed"])
      accumulate_solutions(df, acc)
    end)
    |> materialise_solutions()
  end

  @doc """
  Scan all `seed_testcase` shards (qid pushdown) → `%{qid => [%{stdin,
  expected}]}` for the given `qids`.

  ## Options
    * `:dataset_module` — default `Dataset.Dataset`.
    * `:size_limit` — drop a testcase if `stdin` or `expected` exceeds
      this many bytes (default: no limit). Bounds resident memory by
      discarding the heavy I/O tail at load time.
  """
  @spec testcases(Enumerable.t(), keyword()) :: %{String.t() => [testcase()]}
  def testcases(qids, opts \\ []) do
    dataset = Keyword.get(opts, :dataset_module, Dataset)
    limit = Keyword.get(opts, :size_limit)
    total = dataset.shard_count(:seed_testcase)
    qid_list = Enum.to_list(qids)

    Enum.reduce(0..(total - 1), %{}, fn idx, acc ->
      Logger.info("[corpus] seed_testcase shard #{idx + 1}/#{total}")
      df = dataset.read_testcase_shard(idx, qid_list, ["question_id", "inputs", "outputs"])
      accumulate_testcases(df, acc, limit)
    end)
  end

  @doc """
  Convenience: solutions + testcases (for every solution qid) + stats.
  Loads the full corpus into memory — fine for tests / small fakes; the
  real build uses `solutions/1` + `testcases/2` so it can slice qids.
  """
  @spec grouped(keyword()) :: {map(), map(), stats()}
  def grouped(opts \\ []) do
    solutions_by_qid = solutions(opts)
    testcases_by_qid = testcases(Map.keys(solutions_by_qid), opts)
    {solutions_by_qid, testcases_by_qid, compute_stats(solutions_by_qid, testcases_by_qid)}
  end

  @doc """
  Legacy per-`(qid, solution)` stream `%{id, source, testcases}` (only
  for qids that have testcases). Retained for compatibility.
  """
  @spec build(keyword()) :: {Enumerable.t(), stats()}
  def build(opts \\ []) do
    {solutions_by_qid, testcases_by_qid, stats} = grouped(opts)
    {stream_samples(solutions_by_qid, testcases_by_qid), stats}
  end

  # --- Solutions -------------------------------------------------------

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
        Map.update(acc, qid, MapSet.new([{sha, code}]), &MapSet.put(&1, {sha, code}))
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

  # --- Testcases -------------------------------------------------------

  # `inputs`/`outputs` are JSON-encoded, index-matched lists of strings
  # (all of a qid's testcases packed per row). Decode, zip, append.
  # Rows not decoding to matched string lists (function-call-style) drop.
  defp accumulate_testcases(df, acc, limit) do
    qids = df |> DF.pull("question_id") |> Explorer.Series.to_list()
    inputs = df |> DF.pull("inputs") |> Explorer.Series.to_list()
    outputs = df |> DF.pull("outputs") |> Explorer.Series.to_list()

    [qids, inputs, outputs]
    |> Enum.zip()
    |> Enum.reduce(acc, fn
      {qid, inp, out}, acc when is_binary(qid) and is_binary(inp) and is_binary(out) ->
        case parse_testcases(inp, out, limit) do
          [] -> acc
          tcs -> Map.update(acc, qid, tcs, &(tcs ++ &1))
        end

      _, acc ->
        acc
    end)
  end

  defp parse_testcases(inputs_json, outputs_json, limit) do
    with {:ok, stdins} <- Jason.decode(inputs_json),
         {:ok, expecteds} <- Jason.decode(outputs_json),
         true <- is_list(stdins) and is_list(expecteds),
         true <- length(stdins) == length(expecteds) do
      stdins
      |> Enum.zip(expecteds)
      |> Enum.flat_map(fn
        {stdin, expected} when is_binary(stdin) and is_binary(expected) ->
          if within_limit?(stdin, expected, limit),
            do: [%{stdin: stdin, expected: expected}],
            else: []

        _ ->
          # Non-string entries indicate a function-call-style testcase
          # (args list / dict). Skip — only the stdin/stdout path matters.
          []
      end)
    else
      _ -> []
    end
  end

  defp within_limit?(_stdin, _expected, nil), do: true

  defp within_limit?(stdin, expected, limit),
    do: byte_size(stdin) <= limit and byte_size(expected) <= limit

  # --- Stream / stats --------------------------------------------------

  defp stream_samples(solutions_by_qid, testcases_by_qid) do
    solutions_by_qid
    |> Map.keys()
    |> Enum.sort()
    |> Stream.flat_map(fn qid ->
      case Map.fetch(testcases_by_qid, qid) do
        {:ok, tcs} ->
          Enum.map(Map.fetch!(solutions_by_qid, qid), fn %{sha: sha, source: source} ->
            %{id: "#{qid}--#{String.slice(sha, 0, 8)}", source: source, testcases: tcs}
          end)

        :error ->
          []
      end
    end)
  end

  defp compute_stats(solutions_by_qid, testcases_by_qid) do
    total_solutions =
      solutions_by_qid |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

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

  defp sha256(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
end
