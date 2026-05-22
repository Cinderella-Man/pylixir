defmodule Mix.Tasks.Dataset.Build do
  @shortdoc "Curate the verified Python I/O dataset into out/<version>/"
  @moduledoc """
  Build the curated dataset (Stages 0→4). Thin argv wrapper over
  `Dataset.Build.run/1`.

      mix dataset.build [options]

  ## Options

      --version VER          dataset version dir (default v0)
      --out-dir DIR          override output directory
      --source-revision REV  upstream HF revision recorded in provenance (default main)
      --testcase-shards K    seed_testcase shards loaded (default 1)
      --qid-shard i/N        process only merge-groups in shard i of N (resumable sharding)
      --skip N / --limit N   slice the sorted group list
      --runs N               runs per testcase (default 5)
      --testcase-cap N       max testcases per task (default 32)
      --timeout-ms N         per-run wall-clock budget (default 20000)
      --size-limit BYTES     drop testcases with stdin/expected over this (default 1048576)
      --concurrency N        Select workers (default: schedulers online)
      --as-bytes BYTES       prlimit --as for the sandbox
      --cpu-seconds N        prlimit --cpu for the sandbox
      --no-sandbox           run python unsandboxed (TRUSTED input only)
      --cache-path PATH      verdict cache JSONL
  """
  use Mix.Task

  @switches [
    version: :string,
    out_dir: :string,
    source_revision: :string,
    testcase_shards: :integer,
    qid_shard: :string,
    skip: :integer,
    limit: :integer,
    runs: :integer,
    testcase_cap: :integer,
    timeout_ms: :integer,
    size_limit: :integer,
    concurrency: :integer,
    as_bytes: :integer,
    cpu_seconds: :integer,
    no_sandbox: :boolean,
    cache_path: :string,
    corpus_cache_path: :string
  ]

  @impl true
  def run(argv) do
    {parsed, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    unless invalid == [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    Application.ensure_all_started(:explorer)

    opts =
      parsed
      |> rename(:runs, :run_count)
      |> parse_qid_shard()

    {:ok, out_dir, summary} = Dataset.Build.run(opts)
    Mix.shell().info("kept #{summary.kept}/#{summary.groups} groups → #{out_dir}")
  end

  defp rename(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {val, opts} -> Keyword.put(opts, to, val)
    end
  end

  defp parse_qid_shard(opts) do
    case Keyword.pop(opts, :qid_shard) do
      {nil, opts} ->
        opts

      {spec, opts} ->
        case String.split(spec, "/") do
          [i, n] ->
            Keyword.put(opts, :qid_shard, {String.to_integer(i), String.to_integer(n)})

          _ ->
            Mix.raise("--qid-shard must be i/N, got #{inspect(spec)}")
        end
    end
  end
end
