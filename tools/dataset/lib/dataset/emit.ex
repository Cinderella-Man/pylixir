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
  """

  require Explorer.DataFrame, as: DF

  alias Dataset.Candidates
  alias Dataset.Dataset, as: HF

  @doc """
  Emit `results` (a list of `Dataset.Select` results) into `out/<version>/`.

  ## Options
    * `:out_dir` — full output directory (default `out/<version>`).
    * `:version` — dataset version string (default `"v0"`).
    * `:source_revision` — upstream HF revision (default `"main"`).
    * `:provenance` — extra map merged into `provenance.json`.

  Returns `{:ok, out_dir}`.
  """
  @spec emit([map()], keyword()) :: {:ok, String.t()}
  def emit(results, opts \\ []) do
    version = Keyword.get(opts, :version, "v0")
    out_dir = Keyword.get(opts, :out_dir, Path.join(default_out(), version))
    revision = Keyword.get(opts, :source_revision, "main")

    File.mkdir_p!(out_dir)

    rows = Enum.map(results, &logical_row(&1, revision))

    write_parquet(rows, Path.join(out_dir, "data.parquet"))
    write_jsonl(rows, Path.join(out_dir, "data.jsonl"))
    write_provenance(rows, version, revision, Keyword.get(opts, :provenance, %{}), Path.join(out_dir, "provenance.json"))
    write_card(Path.join(out_dir, "dataset_card.md"))

    {:ok, out_dir}
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

    %{
      "id" => result.id,
      "source" => result.source,
      "solution_sha256" => result.solution_sha256,
      "testcases" => testcases,
      "num_testcases" => length(testcases),
      "meta" => %{
        "member_qids" => result.member_qids,
        "alternate_solution_shas" => result.alternate_solution_shas,
        "source_repo" => HF.source_repo(),
        "source_revision" => revision
      }
    }
  end

  # --- Writers ---------------------------------------------------------

  defp write_parquet(rows, path) do
    df =
      DF.new(
        id: Enum.map(rows, & &1["id"]),
        source: Enum.map(rows, & &1["source"]),
        solution_sha256: Enum.map(rows, & &1["solution_sha256"]),
        testcases: Enum.map(rows, &Jason.encode!(&1["testcases"])),
        num_testcases: Enum.map(rows, & &1["num_testcases"]),
        meta: Enum.map(rows, &Jason.encode!(&1["meta"]))
      )

    DF.to_parquet!(df, path)
  end

  defp write_jsonl(rows, path) do
    body = rows |> Enum.map(&(Jason.encode!(&1) <> "\n")) |> IO.iodata_to_binary()
    File.write!(path, body)
  end

  defp write_provenance(rows, version, revision, extra, path) do
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
      "num_rows" => length(rows),
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
