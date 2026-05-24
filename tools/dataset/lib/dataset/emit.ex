defmodule Dataset.Emit do
  @moduledoc """
  Stage 4 — write the curated dataset. See
  docs/12_dataset-curation-plan.md §Pipeline-4, §Licensing.

  **One row per task.** Parquet columns (via `Explorer.DataFrame`):

      id                String   "<min_qid>--<solution_sha8>"
      source            String   chosen solution's Python source
      solution_sha256   String
      testcases         String   JSON: [{stdin, expected, n_stored_outputs}]
      num_testcases     Int
      meta              String   JSON: {member_qids, alternate_solution_shas,
                                        source_repo, source_revision}

  `testcases`/`meta` are JSON-string columns (avoids Explorer nested-type
  edges). `stdin` is byte-exact; `expected` is the normalized canonical.
  **No problem statement (`question`) is emitted** — see Licensing.

  Outputs into `out/<version>/`: `data.parquet`, `data.jsonl` (the same
  rows, with `testcases`/`meta` as nested JSON for convenience),
  `provenance.json`, `dataset_card.md`.

  ## Memory: streaming, never buffering the whole dataset

  At full-dataset scale the curated rows (with their kept testcase
  payloads) are tens of GB — far too large to hold resident, let alone
  copy several times to build a parquet `DataFrame`. So emit is
  **streaming**: `with_writer/2` opens the output once and the caller
  feeds results in chunks (`write/2`) as each spill bucket finishes;
  each row is appended to disk immediately. `data.parquet` is then
  produced by a **lazy** scan of an on-disk NDJSON sidecar piped through
  Polars' **streaming** parquet sink, so peak memory is one chunk plus a
  Polars batch — independent of total dataset size. `emit/2` is a
  one-shot convenience (open → write → finalize) for tests / small runs.

  Row order is deterministic per caller (the build sorts each bucket by
  `id` before writing); it is **not** a single global `id` sort, since
  each merge-group lands in exactly one bucket and buckets are emitted in
  index order.
  """

  require Explorer.DataFrame, as: DF

  alias Dataset.Candidates
  alias Dataset.Dataset, as: HF

  # Parquet column order (also the `data.jsonl` / NDJSON field order).
  @columns ["id", "source", "solution_sha256", "testcases", "num_testcases", "meta"]

  # Default parquet compression. zstd beats snappy on this corpus (lots of
  # repetitive Python source + I/O text) and is read transparently by
  # pandas/pyarrow/Polars/HuggingFace. Override via `:compression`.
  @compression {:zstd, 3}

  defmodule Writer do
    @moduledoc "Open output handles for streaming emit. See `Dataset.Emit`."
    @enforce_keys [:out_dir, :version, :revision, :jsonl, :ndjson, :ndjson_path, :count]
    defstruct [:out_dir, :version, :revision, :jsonl, :ndjson, :ndjson_path, :count]
  end

  @doc """
  Emit `results` (a list of `Dataset.Select` results) into `out/<version>/`
  in one shot. Convenience wrapper over `with_writer/2` for tests / small
  runs; the build uses `with_writer/2` directly to stream per bucket.

  Returns `{:ok, out_dir}`.
  """
  @spec emit([map()], keyword()) :: {:ok, String.t()}
  def emit(results, opts \\ []) do
    {:ok, out_dir, _n} = with_writer(opts, fn writer -> write(writer, results) end)
    {:ok, out_dir}
  end

  @doc """
  Open the output, run `fun.(writer)` (which streams chunks via `write/2`),
  then finalize — scan the NDJSON sidecar into `data.parquet` (streaming),
  write provenance + card. On a raised error the handles are closed, the
  sidecar removed, and the error re-raised.

  Returns `{:ok, out_dir, num_rows}`.

  ## Options
    * `:out_dir` — full output directory (default `out/<version>`).
    * `:version` — dataset version string (default `"v0"`).
    * `:source_revision` — upstream HF revision (default `"main"`).
    * `:provenance` — extra map merged into `provenance.json`.
    * `:compression` — parquet codec, e.g. `:snappy` or `{:zstd, 3}`
      (default `#{inspect(@compression)}`).
  """
  @spec with_writer(keyword(), (Writer.t() -> any())) :: {:ok, String.t(), non_neg_integer()}
  def with_writer(opts, fun) when is_function(fun, 1) do
    writer = open(opts)

    try do
      fun.(writer)
    rescue
      e ->
        close_handles(writer)
        File.rm(writer.ndjson_path)
        reraise e, __STACKTRACE__
    else
      _ -> finalize(writer, opts)
    end
  end

  @doc """
  Append a chunk of `Dataset.Select` results to the open writer. Each row
  is encoded and written to disk immediately (nested → `data.jsonl`,
  flat string-columns → the NDJSON parquet sidecar); nothing is buffered.
  """
  @spec write(Writer.t(), [map()]) :: :ok
  def write(%Writer{} = writer, results) do
    Enum.each(results, fn result ->
      row = logical_row(result, writer.revision)
      IO.binwrite(writer.jsonl, [Jason.encode_to_iodata!(row), ?\n])

      flat = %{row | "testcases" => Jason.encode!(row["testcases"]), "meta" => Jason.encode!(row["meta"])}
      IO.binwrite(writer.ndjson, [Jason.encode_to_iodata!(flat), ?\n])

      :counters.add(writer.count, 1, 1)
    end)
  end

  # --- Streaming lifecycle ---------------------------------------------

  defp open(opts) do
    version = Keyword.get(opts, :version) || "v0"
    # `|| default` (not Keyword.get/3 default) so an explicit `out_dir: nil`
    # from a caller still falls back instead of crashing mkdir_p!.
    out_dir = Keyword.get(opts, :out_dir) || Path.join(default_out(), version)
    revision = Keyword.get(opts, :source_revision) || "main"

    File.mkdir_p!(out_dir)
    ndjson_path = Path.join(out_dir, ".parquet_rows.ndjson")

    %Writer{
      out_dir: out_dir,
      version: version,
      revision: revision,
      jsonl: File.open!(Path.join(out_dir, "data.jsonl"), [:write, :binary]),
      ndjson: File.open!(ndjson_path, [:write, :binary]),
      ndjson_path: ndjson_path,
      count: :counters.new(1, [:atomics])
    }
  end

  defp finalize(writer, opts) do
    close_handles(writer)
    num_rows = :counters.get(writer.count, 1)

    compression = Keyword.get(opts, :compression, @compression)
    write_parquet(writer.ndjson_path, Path.join(writer.out_dir, "data.parquet"), num_rows, compression)
    File.rm(writer.ndjson_path)

    write_provenance(
      num_rows,
      writer.version,
      writer.revision,
      Keyword.get(opts, :provenance, %{}),
      Path.join(writer.out_dir, "provenance.json")
    )

    write_card(Path.join(writer.out_dir, "dataset_card.md"))
    {:ok, writer.out_dir, num_rows}
  end

  defp close_handles(%Writer{} = writer) do
    File.close(writer.jsonl)
    File.close(writer.ndjson)
  end

  @doc """
  The logical (nested) row for a select result. Exposed for testing.
  """
  @spec logical_row(map(), String.t()) :: map()
  def logical_row(result, revision) do
    testcases =
      Enum.map(result.testcases, fn t ->
        %{"stdin" => t.stdin, "expected" => t.expected, "n_stored_outputs" => t.n_stored_outputs}
      end)

    meta = %{
      "member_qids" => result.member_qids,
      "alternate_solution_shas" => result.alternate_solution_shas,
      "source_repo" => HF.source_repo(),
      "source_revision" => revision
    }

    # Stamped by Dataset.Dedup on a row that absorbed near-duplicate rows.
    meta =
      case Map.get(result, :merged_row_count) do
        nil -> meta
        n -> Map.put(meta, "merged_row_count", n)
      end

    %{
      "id" => result.id,
      "source" => result.source,
      "solution_sha256" => result.solution_sha256,
      "testcases" => testcases,
      "num_testcases" => length(testcases),
      "meta" => meta
    }
  end

  # --- Writers ---------------------------------------------------------

  # Lazy-scan the NDJSON sidecar (flat, JSON-string `testcases`/`meta`
  # columns) and pipe it through Polars' streaming parquet sink, so the
  # whole dataset is never resident. `select/2` pins the column order.
  defp write_parquet(_ndjson_path, parquet_path, 0, compression) do
    @columns
    |> Map.new(&{&1, []})
    |> DF.new()
    |> DF.select(@columns)
    |> DF.to_parquet!(parquet_path, compression: compression)
  end

  defp write_parquet(ndjson_path, parquet_path, _num_rows, compression) do
    ndjson_path
    |> DF.from_ndjson!(lazy: true)
    |> DF.select(@columns)
    |> DF.to_parquet!(parquet_path, streaming: true, compression: compression)
  end

  defp write_provenance(num_rows, version, revision, extra, path) do
    base = %{
      "version" => version,
      "source_repo" => HF.source_repo(),
      "source_revision" => revision,
      "interpreter" => python_version(),
      "runs_per_testcase" => 5,
      "hashseed" => "unset (randomized per run)",
      "normalization" =>
        "utf8(latin1 fallback); CRLF->LF; per-line [ \\t] rstrip; drop trailing blank lines/newline; leading+internal preserved",
      "merge_predicate" => ">=3 shared stdins, 0 disagreements, transitive (connected components)",
      "curation_size_filter_bytes" => Candidates.size_limit(),
      "testcase_cap" => 32,
      "num_rows" => num_rows,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    json = base |> Map.merge(stringify(extra)) |> Jason.encode!(pretty: true)
    File.write!(path, json)
  end

  defp write_card(path) do
    File.write!(path, """
    # Verified Python stdin/stdout dataset

    A curated, **deterministically verifiable** subset of
    [`#{HF.source_repo()}`](https://huggingface.co/datasets/#{HF.source_repo()}).

    ## License
    **CC BY 4.0**, inherited from the upstream dataset
    (`#{HF.source_repo()}`, CC BY 4.0). You must give appropriate
    credit and indicate changes.

    ## Attribution & changes
    Derived from `#{HF.source_repo()}`. Changes from upstream:

    * filtered to a subset whose solution **deterministically reproduces**
      its testcases' outputs (5 runs, byte-identical after normalization);
    * outputs **re-derived and normalized** (the shipped `expected` is the
      solution's normalized stdout, not the raw stored value);
    * **near-duplicate tasks merged** (shared testcases with agreeing
      outputs);
    * **problem statements removed** — only solution source + I/O testcases
      are shipped.

    ## Schema (one row per task)
    `id`, `source`, `solution_sha256`, `testcases` (JSON: `stdin` byte-exact,
    `expected` normalized canonical, `n_stored_outputs`), `num_testcases`,
    `meta` (JSON: `member_qids`, `alternate_solution_shas`, `source_repo`,
    `source_revision`).

    ## Interpreter
    Verified under **#{python_version()}**. Outputs are interpreter-version
    sensitive; compare with the same conservative normalizer (see
    `provenance.json`).
    """)
  end

  # --- Helpers ---------------------------------------------------------

  defp default_out, do: Path.expand("../../out", __DIR__)

  defp python_version do
    case System.cmd(Dataset.default_python(), ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
