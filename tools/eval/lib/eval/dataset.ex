defmodule Eval.Dataset do
  @moduledoc """
  Parquet ingestion for the rStar-Coder HF dataset.

  All HF-specific knowledge (repo name, configs, shard counts, URL
  format) lives in this module. Higher layers (`Eval.Corpus`) treat
  shards as opaque, on-disk parquet files identified by `(config, idx)`.

  Two concrete configs are supported: `:seed_sft` (Python solutions) and
  `:seed_testcase` (joinable testcase set).
  """

  require Explorer.DataFrame, as: DF

  @dataset_repo "microsoft/rStar-Coder"
  @base_url "https://huggingface.co/datasets/#{@dataset_repo}/resolve/main"
  @shard_counts %{seed_sft: 20, seed_testcase: 30}

  @type config :: :seed_sft | :seed_testcase

  @doc """
  Root directory for cached parquet shards.

  Layout:
    cache/parquet/seed_sft/data-00000-of-00020.parquet
    cache/parquet/seed_testcase/data-00000-of-00030.parquet
  """
  @spec cache_dir() :: String.t()
  def cache_dir do
    Path.expand("../../cache/parquet", __DIR__)
  end

  @doc """
  Total number of shards for a given config (from module attribute).
  """
  @spec shard_count(config()) :: pos_integer()
  def shard_count(config) when is_map_key(@shard_counts, config),
    do: Map.fetch!(@shard_counts, config)

  @doc """
  Path where shard `idx` of `config` would land on disk. Does not check
  for presence — pair with `File.exists?/1` or call `download_shard/2`.
  """
  @spec shard_path(config(), non_neg_integer()) :: String.t()
  def shard_path(config, idx) when is_map_key(@shard_counts, config) do
    Path.join([cache_dir(), Atom.to_string(config), filename(idx, shard_count(config))])
  end

  @doc """
  Ensure shard `idx` of `config` is present in `cache_dir/0`. Idempotent:
  returns `{:ok, path}` immediately if the file already exists.

  Implementation:

    * Stream the response body (chunked) into `<path>.partial`.
    * Print a progress line every ~5% or 5 s of wall time.
    * On a complete response, atomic-rename `.partial` → `<path>`.
    * On any failure (network, write, etc.), the `.partial` is removed.
    * No resume logic — a failed download is retried from scratch on the
      next call.
  """
  @spec download_shard(config(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  def download_shard(config, idx) when is_map_key(@shard_counts, config) and is_integer(idx) do
    total = shard_count(config)

    if idx < 0 or idx >= total do
      raise ArgumentError,
            "shard index #{idx} out of range for #{config} (have #{total} shards)"
    end

    name = filename(idx, total)
    path = Path.join([cache_dir(), Atom.to_string(config), name])
    partial = path <> ".partial"

    cond do
      File.exists?(path) ->
        {:ok, path}

      true ->
        # A leftover `.partial` from a previous crash is unrecoverable
        # (no resume) — start fresh.
        _ = File.rm(partial)
        File.mkdir_p!(Path.dirname(path))

        url = "#{@base_url}/#{config}/#{name}"
        label = "#{config}/#{name}"

        case stream_to_file(url, partial, label) do
          :ok ->
            File.rename!(partial, path)
            {:ok, path}

          {:error, reason} ->
            _ = File.rm(partial)
            {:error, reason}
        end
    end
  end

  @doc """
  Read a `seed_sft` shard, projecting `cols`. Eager — full shard fits in
  memory after projection (~50 MB compressed → ~150 MB Polars frame).
  """
  @spec read_sft_shard(non_neg_integer(), [String.t()]) :: Explorer.DataFrame.t()
  def read_sft_shard(idx, cols) do
    {:ok, path} = download_shard(:seed_sft, idx)
    DF.from_parquet!(path, columns: cols)
  end

  @doc """
  Read a `seed_testcase` shard, projecting `cols` and pushing the
  `question_id ∈ qid_filter` predicate down into Polars. Only rows whose
  qid is in the filter are materialised — important because raw
  testcase shards are ~5 GB each.

  `qid_filter` is any enumerable of qid strings; converted to a list
  once for Polars' `is_in`.
  """
  @spec read_testcase_shard(non_neg_integer(), Enumerable.t(), [String.t()]) ::
          Explorer.DataFrame.t()
  def read_testcase_shard(idx, qid_filter, cols) do
    {:ok, path} = download_shard(:seed_testcase, idx)
    qids = Enum.to_list(qid_filter)

    path
    |> DF.from_parquet!(columns: cols, lazy: true)
    |> DF.filter(question_id in ^qids)
    |> DF.collect()
  end

  # --- Internals -------------------------------------------------------

  @spec filename(non_neg_integer(), pos_integer()) :: String.t()
  defp filename(idx, total) do
    "data-#{pad5(idx)}-of-#{pad5(total)}.parquet"
  end

  defp pad5(n), do: n |> Integer.to_string() |> String.pad_leading(5, "0")

  @progress_key {__MODULE__, :progress}

  defp stream_to_file(url, dest, label) do
    handle = File.open!(dest, [:write, :binary])

    Process.put(@progress_key, %{
      handle: handle,
      bytes: 0,
      total_bytes: nil,
      next_pct: 5,
      last_ms: System.monotonic_time(:millisecond),
      label: label
    })

    try do
      resp =
        Req.get!(url,
          connect_options: [timeout: 30_000],
          receive_timeout: 600_000,
          into: &write_chunk/2
        )

      if resp.status == 200 do
        IO.puts("[dataset] #{label}: done")
        :ok
      else
        {:error, {:bad_status, resp.status}}
      end
    catch
      kind, reason ->
        {:error, {kind, reason}}
    after
      File.close(handle)
      Process.delete(@progress_key)
    end
  end

  # Req's `:into` callback fires for each chunk of every response in
  # the redirect chain — including the 302's HTML body ("Found.
  # Redirecting to ..."). Writing those chunks corrupts the parquet
  # (it ends up prefixed with the redirect body). Filter to 2xx
  # responses only; the redirect chain still happens, we just don't
  # let intermediate bodies hit the file. Same filter resets the
  # content-length capture so we grab the *final* response's length
  # (the 302's content-length is the size of its own HTML body, not
  # the parquet).
  defp write_chunk({:data, chunk}, {req, %{status: status} = resp})
       when status in 200..299 do
    state = Process.get(@progress_key)

    IO.binwrite(state.handle, chunk)
    bytes = state.bytes + byte_size(chunk)

    total = state.total_bytes || content_length(resp)
    state = maybe_log_progress(state, bytes, total)

    Process.put(@progress_key, %{state | bytes: bytes, total_bytes: total})
    {:cont, {req, resp}}
  end

  defp write_chunk({:data, _chunk}, {req, resp}) do
    {:cont, {req, resp}}
  end

  defp content_length(%Req.Response{headers: headers}) do
    case Map.get(headers, "content-length") do
      [val] -> safe_to_int(val)
      val when is_binary(val) -> safe_to_int(val)
      _ -> nil
    end
  end

  defp safe_to_int(val) do
    case Integer.parse(val) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp maybe_log_progress(state, bytes, total) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = now - state.last_ms

    # `total` is the captured `Content-Length`. If the response is
    # transfer-encoded (gzip, chunked) or content-length is otherwise
    # inaccurate, `bytes` can exceed `total` — guard against the
    # "41,000,000%" output that produces.
    pct_known? = is_integer(total) and total > 0 and bytes <= total

    pct_threshold_hit? =
      pct_known? and bytes * 100 >= state.next_pct * total

    if pct_threshold_hit? or elapsed_ms >= 5_000 do
      pct_str =
        if pct_known?,
          do: "#{trunc(bytes * 100 / total)}%",
          else: "?%"

      mb = :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)
      IO.puts("[dataset] #{state.label}: #{pct_str} (#{mb} MB)")

      %{state | last_ms: now, next_pct: state.next_pct + 5}
    else
      state
    end
  end
end
