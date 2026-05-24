defmodule Eval.Dataset do
  @moduledoc """
  Fetches the curated evaluation dataset — a single self-contained parquet.

  The eval corpus is now the published, pre-verified dataset
  [`#{"CinderellaMan/rstar-coder-verified-io-deduped"}`](https://huggingface.co/datasets/CinderellaMan/rstar-coder-verified-io-deduped):
  one `data.parquet` (~1.6 GB) whose every row carries `id`, `source`
  (the solution) and `testcases` (stdin + the verified, normalized
  `expected`). There is no join, dedup, or `is_passed` filter to do — the
  dataset is already curated (see `tools/dataset`).

  `ensure_parquet/0` downloads the file once to `cache/data.parquet`
  (idempotent) and returns its path. To refresh after a new dataset
  release, delete `cache/data.parquet`. The download reuses the chunked
  `Req` streamer (filters the HF 302→CDN-LFS redirect so the parquet
  isn't prefixed with the redirect body).
  """

  @repo "CinderellaMan/rstar-coder-verified-io-deduped"
  @filename "data.parquet"
  @url "https://huggingface.co/datasets/#{@repo}/resolve/main/#{@filename}"

  @doc """
  On-disk path of the cached parquet (default location, may not exist).
  """
  @spec parquet_path() :: String.t()
  def parquet_path do
    Path.join(Path.expand("../../cache", __DIR__), @filename)
  end

  @doc """
  Ensure the curated `data.parquet` is present in `cache/` and return its
  path. Idempotent: returns immediately if the file already exists;
  otherwise streams it from HuggingFace.
  """
  @spec ensure_parquet() :: {:ok, String.t()} | {:error, term()}
  def ensure_parquet do
    path = parquet_path()
    partial = path <> ".partial"

    if File.exists?(path) do
      {:ok, path}
    else
      _ = File.rm(partial)
      File.mkdir_p!(Path.dirname(path))

      case stream_to_file(@url, partial, @filename) do
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
  Like `ensure_parquet/0` but raises on failure, returning the path.
  """
  @spec ensure_parquet!() :: String.t()
  def ensure_parquet! do
    case ensure_parquet() do
      {:ok, path} -> path
      {:error, reason} -> raise "failed to download #{@url}: #{inspect(reason)}"
    end
  end

  # --- Chunked download (unchanged from the shard-streaming era) -------

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

  # Req's `:into` callback fires for each chunk of every response in the
  # redirect chain — including the 302's HTML body. Writing those chunks
  # corrupts the parquet, so filter to 2xx responses only; the same filter
  # captures the *final* response's content-length for the progress meter.
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

    pct_known? = is_integer(total) and total > 0 and bytes <= total
    pct_threshold_hit? = pct_known? and bytes * 100 >= state.next_pct * total

    if pct_threshold_hit? or elapsed_ms >= 5_000 do
      pct_str = if pct_known?, do: "#{trunc(bytes * 100 / total)}%", else: "?%"
      mb = :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)
      IO.puts("[dataset] #{state.label}: #{pct_str} (#{mb} MB)")

      %{state | last_ms: now, next_pct: state.next_pct + 5}
    else
      state
    end
  end
end
