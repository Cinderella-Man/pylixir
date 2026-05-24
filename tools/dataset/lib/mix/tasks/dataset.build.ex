defmodule Mix.Tasks.Dataset.Build do
  @shortdoc "Curate the verified Python I/O dataset into out/<version>/"
  @moduledoc """
  Build the curated dataset (Stages 0→4). Thin argv wrapper over
  `Dataset.Build.run/1`.

      mix dataset.build [options]

  By default this processes the **entire** dataset and dedups (merges
  near-duplicate tasks) **globally** — near-dup detection always runs over
  all shards/qids first, regardless of any slicing. Memory stays bounded at
  any scale **without** manual sharding: the raw shards (hundreds of GB) are
  streamed from disk, filtered testcases are spilled to on-disk buckets, and
  the build processes one bucket at a time. `--qid-shard` remains purely
  optional — for splitting one run across processes/machines.

  ## Options

      --version VER          dataset version dir (default v0)
      --out-dir DIR          override output directory
      --source-revision REV  upstream HF revision recorded in provenance (default main)
      --qid-shard i/N        OPTIONAL. Default = whole dataset. Splits one run across N
                             processes/machines (shards by group, after global dedup); also
                             bounds resident testcase memory. Omit it to process everything.
      --skip N / --limit N   slice the sorted group list
      --runs N               runs per testcase (default 5)
      --testcase-cap N       max testcases per task (default 32)
      --dedup-min-shared N   global post-dedup: min shared stdins to merge two
                             shipped rows (default 2; 3 = merge rule, 1 = max)
      --source-norm MODE     dedup source signal via Python AST: struct (default,
                             ignores names+formatting) | reformat | none
      --behavioral           ALSO dedup by behavioral equivalence: merge two rows
                             if each solution reproduces all the other's testcases
                             (runs python on candidate pairs; slower, resumable)
      --behavioral-run-count N  determinism runs for behavioral checks (default: --runs)
      --no-dedup             skip the post-selection dedup pass entirely
      --solution-cap N       max candidate solutions tried per task, shortest-first (default 100)
      --timeout-ms N         per-run wall-clock budget (default 20000)
      --size-limit BYTES     drop testcases with stdin/expected over this (default 1048576)
      --concurrency N        Select workers (default: schedulers online)
      --as-bytes BYTES       prlimit --as for the sandbox
      --cpu-seconds N        prlimit --cpu for the sandbox
      --no-sandbox           run python unsandboxed (TRUSTED input only)
      --cache-path PATH      verdict cache JSONL
  """
  use Mix.Task

  # Boot the application (and all deps: req/finch, explorer, jason) before
  # running — the pipeline downloads shards via Req, which needs Finch's
  # supervisor started.
  @requirements ["app.start"]

  @switches [
    version: :string,
    out_dir: :string,
    source_revision: :string,
    qid_shard: :string,
    skip: :integer,
    limit: :integer,
    runs: :integer,
    testcase_cap: :integer,
    dedup_min_shared: :integer,
    source_norm: :string,
    behavioral: :boolean,
    behavioral_run_count: :integer,
    no_dedup: :boolean,
    solution_cap: :integer,
    timeout_ms: :integer,
    size_limit: :integer,
    concurrency: :integer,
    as_bytes: :integer,
    cpu_seconds: :integer,
    no_sandbox: :boolean,
    cache_path: :string
  ]

  @impl true
  def run(argv) do
    {parsed, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    unless invalid == [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    opts =
      parsed
      |> rename(:runs, :run_count)
      |> parse_qid_shard()
      |> parse_no_dedup()

    {:ok, out_dir, summary} = Dataset.Build.run(opts)
    Mix.shell().info("kept #{summary.kept}/#{summary.groups} groups → #{out_dir}")
  end

  defp rename(opts, from, to) do
    case Keyword.pop(opts, from) do
      {nil, opts} -> opts
      {val, opts} -> Keyword.put(opts, to, val)
    end
  end

  defp parse_no_dedup(opts) do
    case Keyword.pop(opts, :no_dedup) do
      {true, opts} -> Keyword.put(opts, :dedup_min_shared, 0)
      {_, opts} -> opts
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
