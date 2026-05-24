defmodule Dataset.Spill do
  @moduledoc """
  Disk-spill for testcases so the build processes the **whole dataset**
  with bounded memory, no matter how large. See
  docs/12_dataset-curation-plan.md §Resumability.

  Testcases are organized by shard, not by task, and the full filtered set
  can be tens-to-hundreds of GB — too big to hold in RAM. So:

    1. `run/3` streams every `seed_testcase` shard **once**, and routes
       each (size-filtered) testcase to one of `B` on-disk **bucket files**
       keyed by `phash2(group_id, B)`. Because routing is by *group*, all
       of a merge-group's testcases (across all member qids and all shards)
       land in the same bucket.
    2. `read_bucket/2` loads one bucket back as `%{qid => [%{stdin,
       expected}]}` — bounded by ~`total / B`.

  Peak memory is then ~one testcase shard (during the spill) and ~one
  bucket (during processing), independent of total dataset size. Records
  are length-prefixed `:erlang.term_to_binary` so arbitrary stdin/expected
  bytes round-trip exactly. The bucket dir is transient (cleaned by
  `cleanup/1`); verification resumability lives in the verdict cache.
  """

  alias Dataset.Dataset
  require Explorer.DataFrame, as: DF
  require Logger

  @max_buckets 256

  @doc """
  Stream all testcase shards and spill filtered testcases to bucket files,
  keeping only testcases whose group is in `selected_gids`.

  Returns `{dir, n_buckets}`.

  ## Options
    * `:dataset_module` — default `Dataset.Dataset`.
    * `:size_limit` — drop a testcase if stdin/expected exceeds this.
    * `:buckets` — max buckets (default #{@max_buckets}); clamped to the
      number of selected groups.
    * `:dir` — spill directory (default a fresh temp dir).
  """
  @spec run(%{String.t() => String.t()}, MapSet.t(), keyword()) :: {String.t(), pos_integer()}
  def run(qid_to_group, selected_gids, opts \\ []) do
    dataset = Keyword.get(opts, :dataset_module, Dataset)
    limit = Keyword.get(opts, :size_limit)
    max_buckets = Keyword.get(opts, :buckets, @max_buckets)

    dir =
      Keyword.get(opts, :dir) ||
        Path.join(System.tmp_dir!(), "dataset_spill_#{System.unique_integer([:positive])}")

    buckets = max(1, min(max_buckets, MapSet.size(selected_gids)))
    File.mkdir_p!(dir)

    needed_qids =
      for {qid, gid} <- qid_to_group, MapSet.member?(selected_gids, gid), do: qid

    handles = for b <- 0..(buckets - 1), into: %{}, do: {b, File.open!(path(dir, b), [:write, :binary])}

    total = dataset.shard_count(:seed_testcase)

    try do
      Enum.each(0..(total - 1), fn idx ->
        Logger.info("[spill] seed_testcase shard #{idx + 1}/#{total}")
        df = dataset.read_testcase_shard(idx, needed_qids, ["question_id", "inputs", "outputs"])
        write_shard(df, handles, qid_to_group, selected_gids, buckets, limit)
      end)
    after
      Enum.each(handles, fn {_b, h} -> File.close(h) end)
    end

    {dir, buckets}
  end

  @doc "Read one bucket back as `%{qid => [%{stdin, expected}]}`."
  @spec read_bucket(String.t(), non_neg_integer()) :: %{String.t() => [map()]}
  def read_bucket(dir, b) do
    case File.read(path(dir, b)) do
      {:ok, bin} -> bin |> decode_records([]) |> group_by_qid()
      _ -> %{}
    end
  end

  @doc "Remove the spill directory."
  @spec cleanup(String.t()) :: :ok
  def cleanup(dir), do: File.rm_rf(dir) |> elem(0) |> then(fn _ -> :ok end)

  # --- Internals -------------------------------------------------------

  defp write_shard(df, handles, qid_to_group, selected_gids, buckets, limit) do
    qids = df |> DF.pull("question_id") |> Explorer.Series.to_list()
    inputs = df |> DF.pull("inputs") |> Explorer.Series.to_list()
    outputs = df |> DF.pull("outputs") |> Explorer.Series.to_list()

    [qids, inputs, outputs]
    |> Enum.zip()
    |> Enum.each(fn
      {qid, inp, out} when is_binary(qid) and is_binary(inp) and is_binary(out) ->
        case Map.get(qid_to_group, qid) do
          nil ->
            :ok

          gid ->
            if MapSet.member?(selected_gids, gid) do
              b = rem(:erlang.phash2(gid, buckets), buckets)
              handle = Map.fetch!(handles, b)

              for {stdin, expected} <- parse_pairs(inp, out, limit) do
                rec = :erlang.term_to_binary({qid, stdin, expected})
                IO.binwrite(handle, <<byte_size(rec)::32, rec::binary>>)
              end
            end
        end

      _ ->
        :ok
    end)
  end

  defp parse_pairs(inputs_json, outputs_json, limit) do
    with {:ok, ins} <- Jason.decode(inputs_json),
         {:ok, outs} <- Jason.decode(outputs_json),
         true <- is_list(ins) and is_list(outs) and length(ins) == length(outs) do
      ins
      |> Enum.zip(outs)
      |> Enum.flat_map(fn
        {s, e} when is_binary(s) and is_binary(e) ->
          if within_limit?(s, e, limit), do: [{s, e}], else: []

        _ ->
          []
      end)
    else
      _ -> []
    end
  end

  defp within_limit?(_s, _e, nil), do: true
  defp within_limit?(s, e, limit), do: byte_size(s) <= limit and byte_size(e) <= limit

  defp decode_records(<<>>, acc), do: Enum.reverse(acc)

  defp decode_records(<<len::32, rec::binary-size(len), rest::binary>>, acc),
    do: decode_records(rest, [:erlang.binary_to_term(rec) | acc])

  defp group_by_qid(records) do
    Enum.reduce(records, %{}, fn {qid, stdin, expected}, acc ->
      tc = %{stdin: stdin, expected: expected}
      Map.update(acc, qid, [tc], &[tc | &1])
    end)
  end

  defp path(dir, b), do: Path.join(dir, "bucket-#{String.pad_leading(Integer.to_string(b), 4, "0")}")
end
