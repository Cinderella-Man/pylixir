defmodule Dataset.Dataset do
  @moduledoc """
  Parquet ingestion for the rStar-Coder HF dataset.

  All HF-specific knowledge (repo name, configs, shard counts, URL
  format) lives in this module. Higher layers (`Dataset.Corpus`) treat
  shards as opaque, on-disk parquet files identified by `(config, idx)`.

  Two concrete configs are supported: `:seed_sft` (Python solutions) and
  `:seed_testcase` (joinable testcase set).

  Copied verbatim from `Eval.Dataset` (pure data ingestion, no pylixir);
  only the module namespace differs. See docs/12_dataset-curation-plan.md.
  """

  require Explorer.DataFrame, as: DF
  require Logger

  @dataset_repo "microsoft/rStar-Coder"
  @shard_counts %{seed_sft: 20, seed_testcase: 30}

  @type config :: :seed_sft | :seed_testcase

  @doc """
  The upstream HuggingFace dataset repo id.
  """
  @spec source_repo() :: String.t()
  def source_repo, do: @dataset_repo

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

  Downloads via the `hf` CLI (`huggingface_hub`), which handles multi-GB
  LFS files with resume and **hash verification** — unlike a plain
  streaming HTTP GET, which can silently truncate a 10 GB+ shard. The
  file lands at `cache_dir()/<config>/<name>` (hf places repo-relative
  paths under `--local-dir`).
  """
  @spec download_shard(config(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  def download_shard(config, idx) when is_map_key(@shard_counts, config) and is_integer(idx) do
    total = shard_count(config)

    if idx < 0 or idx >= total do
      raise ArgumentError,
            "shard index #{idx} out of range for #{config} (have #{total} shards)"
    end

    path = shard_path(config, idx)

    if File.exists?(path) do
      {:ok, path}
    else
      hf_download(config, idx, path)
    end
  end

  defp hf_download(config, idx, path) do
    repo_path = "#{config}/#{filename(idx, shard_count(config))}"
    Logger.info("[dataset] hf download #{repo_path}")
    File.mkdir_p!(cache_dir())

    args = [
      "download",
      @dataset_repo,
      repo_path,
      "--repo-type",
      "dataset",
      "--local-dir",
      cache_dir()
    ]

    case System.cmd("hf", args, stderr_to_stdout: true) do
      {_out, 0} ->
        if File.exists?(path),
          do: {:ok, path},
          else: {:error, {:missing_after_download, path}}

      {out, status} ->
        {:error, {:hf_failed, status, String.slice(out, -2000, 2000)}}
    end
  rescue
    e in ErlangError -> {:error, {:hf_not_runnable, Exception.message(e)}}
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
end
