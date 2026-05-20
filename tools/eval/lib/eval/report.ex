defmodule Eval.Report do
  @moduledoc """
  Persist an `Eval.run/1` accumulator to disk under
  `reports/run-<ISO8601>/`:

    * `summary.md` — human-readable per-run summary.
    * `summary.json` — machine-readable counts (for cross-run diffing).
      Carries `schema_version: 2` and a run-level `comparison_mode`
      (`"executed"` for full behavioral checks, `"compile_only"` for
      `--no-execute` runs).
    * `failures/<bucket-slug>/<n>.py` — first samples per bucket so
      maintainers can copy promising ones into `test/fixtures/python/`.
    * `mismatches/<fingerprint>/<n>.{py,ex,expected.txt,actual.txt,diff}`
      — output-mismatch samples with both stdouts and a diff summary
      so reviewers can triage without re-running the harness.
  """

  alias Eval.Bucket

  @schema_version 2

  @doc """
  Write the report. Returns the absolute path to the run directory.

  ## Options

    * `:out` — explicit output directory. Defaults to
      `reports/run-<ISO8601>/`.
    * `:comparison_mode` — `:executed | :compile_only`. Embedded in
      `summary.json` so cross-run comparisons are unambiguous about
      what `:ok` means.
  """
  @spec write(Eval.accumulator(), keyword()) :: Path.t()
  def write(accumulator, opts \\ []) do
    run_dir = opts[:out] || default_run_dir()
    comparison_mode = opts[:comparison_mode] || :executed

    File.mkdir_p!(run_dir)

    write_json(run_dir, accumulator, comparison_mode)
    write_markdown(run_dir, accumulator, comparison_mode)
    write_failure_samples(run_dir, accumulator)
    write_mismatch_samples(run_dir, accumulator)
    write_ok_samples(run_dir, accumulator)

    run_dir
  end

  defp default_run_dir do
    ts =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace(":", "-")

    Path.join([reports_root(), "run-#{ts}"])
  end

  # __DIR__ resolves to tools/eval/lib/eval/ at compile time; the canonical
  # reports root sits at tools/eval/reports/, two levels up.
  defp reports_root, do: Path.expand("../../reports", __DIR__)

  defp write_json(run_dir, acc, comparison_mode) do
    derived = derived_totals(acc)

    payload = %{
      schema_version: @schema_version,
      comparison_mode: Atom.to_string(comparison_mode),
      totals: Map.merge(acc.totals, derived),
      counts:
        for {key, n} <- acc.counts, into: %{} do
          {Bucket.slug(key), %{count: n, key: inspect(key)}}
        end
    }

    File.write!(Path.join(run_dir, "summary.json"), Jason.encode!(payload, pretty: true))
  end

  defp write_markdown(run_dir, acc, comparison_mode) do
    sorted = Enum.sort_by(acc.counts, fn {_k, n} -> -n end)
    total = acc.totals.processed
    derived = derived_totals(acc)

    headline_label =
      case comparison_mode do
        :executed -> "Behavioral equivalence"
        :compile_only -> "Compile-success"
      end

    headline_count = derived.equivalent + derived.compile_only_ok
    headline_pct = format_pct(headline_count, total)

    behavior_rows = bucket_rows(sorted, total, &behavior_bucket?/1)
    compile_rows = bucket_rows(sorted, total, &compile_stage_bucket?/1)
    python_rows = bucket_rows(sorted, total, &python_bucket?/1)

    body = """
    # Pylixir eval run

    | metric | value |
    | --- | --- |
    | comparison mode | `#{comparison_mode}` |
    | processed | #{total} |
    | skipped (no Python extracted) | #{acc.totals.skipped} |
    | #{headline_label} | #{headline_count} (#{headline_pct}%) |
    | equivalent (`:ok` + `:ok_empty_output`) | #{derived.equivalent} |
    | python preflight failures | #{derived.python_failed} |
    | nondeterministic | #{derived.nondeterministic} |

    ## Behavior buckets

    | bucket | count | share |
    | --- | --- | --- |
    #{behavior_rows}

    ## Transpile / Compile buckets

    | bucket | count | share |
    | --- | --- | --- |
    #{compile_rows}

    ## Python preflight buckets

    | bucket | count | share |
    | --- | --- | --- |
    #{python_rows}

    Per-bucket failure samples are in `failures/<bucket-slug>/`.
    Mismatch samples are in `mismatches/<fingerprint>/`.
    """

    File.write!(Path.join(run_dir, "summary.md"), body)
  end

  defp bucket_rows(sorted, total, predicate) do
    rows =
      sorted
      |> Enum.filter(fn {k, _} -> predicate.(k) end)
      |> Enum.map_join("\n", fn {key, n} ->
        "| `#{Bucket.slug(key)}` | #{n} | #{format_pct(n, total)}% |"
      end)

    if rows == "", do: "| _(none)_ | 0 | 0.0% |", else: rows
  end

  defp behavior_bucket?(:ok), do: true
  defp behavior_bucket?(:ok_empty_output), do: true
  defp behavior_bucket?({:output_mismatch, _}), do: true
  defp behavior_bucket?({:elixir_runtime_error, _}), do: true
  defp behavior_bucket?(:elixir_timeout), do: true
  defp behavior_bucket?(_), do: false

  defp compile_stage_bucket?({:unsupported, _}), do: true
  defp compile_stage_bucket?(:parse_error), do: true
  defp compile_stage_bucket?({:compile_error, _}), do: true
  defp compile_stage_bucket?({:internal, _}), do: true
  defp compile_stage_bucket?(_), do: false

  defp python_bucket?(:python_syntax_error), do: true
  defp python_bucket?(:python_import_error), do: true
  defp python_bucket?({:python_error, _}), do: true
  defp python_bucket?(:python_timeout), do: true
  defp python_bucket?(:nondeterministic_observed), do: true
  defp python_bucket?(_), do: false

  defp derived_totals(acc) do
    counts = acc.counts

    equivalent = (counts[:ok] || 0) + (counts[:ok_empty_output] || 0)

    # In compile-only mode there's no behavioral signal — the same
    # `:ok` count represents "transpile + compile clean", surfaced
    # under a different headline label in the markdown.
    compile_only_ok = 0

    python_failed =
      Enum.reduce(counts, 0, fn {key, n}, sum ->
        if python_bucket?(key), do: sum + n, else: sum
      end)

    nondeterministic = counts[:nondeterministic_observed] || 0

    %{
      equivalent: equivalent,
      compile_only_ok: compile_only_ok,
      python_failed: python_failed,
      nondeterministic: nondeterministic
    }
  end

  defp format_pct(_n, 0), do: "0.0"

  defp format_pct(n, total),
    do: :erlang.float_to_binary(n / total * 100, decimals: 1)

  defp write_failure_samples(run_dir, acc) do
    failures_root = Path.join(run_dir, "failures")
    File.mkdir_p!(failures_root)

    Enum.each(acc.samples, fn {bucket_key, entries} ->
      cond do
        entries == [] -> :ok
        bucket_key == :ok -> :ok
        bucket_key == :ok_empty_output -> :ok
        match?({:output_mismatch, _}, bucket_key) -> :ok
        true -> write_bucket_entries(failures_root, bucket_key, entries)
      end
    end)
  end

  defp write_bucket_entries(root, bucket_key, entries) do
    bucket_dir = Path.join(root, Bucket.slug(bucket_key))
    File.mkdir_p!(bucket_dir)

    entries
    |> Enum.with_index(1)
    |> Enum.each(fn {entry, idx} ->
      padded = String.pad_leading(Integer.to_string(idx), 3, "0")
      file = Path.join(bucket_dir, "#{padded}.py")
      File.write!(file, build_sample_file(bucket_key, entry))
    end)
  end

  defp write_mismatch_samples(run_dir, acc) do
    mismatch_buckets =
      Enum.filter(acc.samples, fn {key, entries} ->
        match?({:output_mismatch, _}, key) and entries != []
      end)

    if mismatch_buckets != [] do
      root = Path.join(run_dir, "mismatches")
      File.mkdir_p!(root)

      Enum.each(mismatch_buckets, fn {{:output_mismatch, fp}, entries} ->
        bucket_dir = Path.join(root, sanitize_fp(fp))
        File.mkdir_p!(bucket_dir)

        entries
        |> Enum.with_index(1)
        |> Enum.each(fn {entry, idx} ->
          padded = String.pad_leading(Integer.to_string(idx), 3, "0")
          write_mismatch_entry(bucket_dir, padded, entry)
        end)
      end)
    end
  end

  defp write_mismatch_entry(dir, padded, entry) do
    File.write!(Path.join(dir, "#{padded}.py"), entry.source)

    case entry.metadata[:elixir_source] do
      nil -> :ok
      src -> File.write!(Path.join(dir, "#{padded}.ex"), src)
    end

    File.write!(
      Path.join(dir, "#{padded}.expected.txt"),
      entry.metadata[:python_stdout] || ""
    )

    File.write!(
      Path.join(dir, "#{padded}.actual.txt"),
      entry.metadata[:elixir_stdout] || ""
    )

    File.write!(
      Path.join(dir, "#{padded}.diff"),
      entry.metadata[:diff_summary] || ""
    )
  end

  defp sanitize_fp(fp) do
    fp
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.slice(0, 80)
  end

  # `--save-ok N` populates `accumulator.samples[:ok]` (capped by N).
  # For each entry, write the Python source and the generated Elixir
  # side-by-side under `reports/<ts>/ok/`. Browse the directory to see
  # real Python → Elixir pairs; pair well with `mix eval.show` for
  # one-off pretty-print. Skipped silently when no OK samples were
  # collected (the default, since `--save-ok` defaults to 0).
  defp write_ok_samples(run_dir, acc) do
    entries = Map.get(acc.samples, :ok, []) ++ Map.get(acc.samples, :ok_empty_output, [])

    unless entries == [] do
      ok_dir = Path.join(run_dir, "ok")
      File.mkdir_p!(ok_dir)

      entries
      |> Enum.with_index(1)
      |> Enum.each(fn {entry, idx} ->
        padded = String.pad_leading(Integer.to_string(idx), 3, "0")
        py_path = Path.join(ok_dir, "#{padded}.py")
        ex_path = Path.join(ok_dir, "#{padded}.ex")

        File.write!(py_path, build_ok_python_file(entry))

        case entry.metadata[:elixir_source] do
          nil -> :ok
          src -> File.write!(ex_path, src)
        end
      end)
    end
  end

  defp build_ok_python_file(entry) do
    """
    # sample id: #{entry.id}
    # bucket: :ok
    # see the matching <NNN>.ex in this directory for the generated Elixir

    #{entry.source}
    """
  end

  defp build_sample_file(bucket_key, entry) do
    # Comment-prefix every line of the inspect so multi-line metadata
    # stays as valid Python (the failure-sample file is meant to be
    # re-runnable through CPython / Pylixir without manual editing).
    metadata_lines =
      entry.metadata
      |> inspect(pretty: true, limit: :infinity)
      |> String.split("\n")
      |> Enum.map_join("\n", &("# " <> &1))

    """
    # sample id: #{entry.id}
    # bucket: #{inspect(bucket_key)}
    # metadata:
    #{metadata_lines}

    #{entry.source}
    """
  end
end
