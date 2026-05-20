defmodule Eval.Report do
  @moduledoc """
  Persist an `Eval.run/1` accumulator to disk under
  `reports/run-<ISO8601>/`:

    * `summary.md` — human-readable per-run summary. Includes a hint
      line when `testcase_shard_missing > 0` (passing solutions whose
      testcases live in a shard not loaded under the current
      `--testcase-shards K`).
    * `summary.json` — machine-readable counts. Carries
      `schema_version: 3` plus `totals.testcases_run`,
      `totals.testcases_passed`, `totals.testcase_shard_missing`.
    * `failures/<bucket-slug>/<n>.py` — first samples per bucket so
      maintainers can copy promising ones into `test/fixtures/python/`.
    * `mismatches/<fingerprint>/<n>.{py,ex,summary.md}` plus per-failing-
      testcase `<n>.testcase_<idx>.{stdin,expected,python,elixir,diff}.txt`
      — output-mismatch and python-disagrees-expected samples with
      enough detail to triage without re-running the harness.
  """

  alias Eval.Bucket

  @schema_version 3

  @doc """
  Write the report. Returns the absolute path to the run directory.

  ## Options

    * `:out` — explicit output directory. Defaults to
      `reports/run-<ISO8601>/`.
    * `:comparison_mode` — currently always `:executed`. Embedded in
      `summary.json` for forward-compatibility with future modes.
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

  # --- summary.json ----------------------------------------------------

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

  # --- summary.md ------------------------------------------------------

  defp write_markdown(run_dir, acc, comparison_mode) do
    sorted = Enum.sort_by(acc.counts, fn {_k, n} -> -n end)
    total = acc.totals.processed
    derived = derived_totals(acc)

    headline_count = derived.equivalent
    headline_pct = format_pct(headline_count, total)

    behavior_rows = bucket_rows(sorted, total, &behavior_bucket?/1)
    compile_rows = bucket_rows(sorted, total, &compile_stage_bucket?/1)
    python_rows = bucket_rows(sorted, total, &python_bucket?/1)

    shard_hint = testcase_shard_hint(acc.totals)

    body = """
    # Pylixir eval run

    | metric | value |
    | --- | --- |
    | comparison mode | `#{comparison_mode}` |
    | processed | #{total} |
    | behavioral equivalence | #{headline_count} (#{headline_pct}%) |
    | equivalent (`:ok` + `:ok_empty_output`) | #{derived.equivalent} |
    | python preflight failures | #{derived.python_failed} |
    | nondeterministic | #{derived.nondeterministic} |
    | testcases run | #{acc.totals.testcases_run} |
    | testcases passed | #{acc.totals.testcases_passed} |
    #{shard_hint}
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

  defp testcase_shard_hint(%{testcase_shard_missing: 0}), do: ""

  defp testcase_shard_hint(%{testcase_shard_missing: n}) do
    "\n> #{n} passing solutions have testcases in seed_testcase shards not loaded " <>
      "(current: see config; total available: 30). Pass `--testcase-shards K'` to include more.\n"
  end

  defp testcase_shard_hint(_), do: ""

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
  defp behavior_bucket?({:python_disagrees_expected, _}), do: true
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

    python_failed =
      Enum.reduce(counts, 0, fn {key, n}, sum ->
        if python_bucket?(key), do: sum + n, else: sum
      end)

    nondeterministic = counts[:nondeterministic_observed] || 0

    %{
      equivalent: equivalent,
      python_failed: python_failed,
      nondeterministic: nondeterministic
    }
  end

  defp format_pct(_n, 0), do: "0.0"

  defp format_pct(n, total),
    do: :erlang.float_to_binary(n / total * 100, decimals: 1)

  # --- failures/<bucket>/ ----------------------------------------------

  defp write_failure_samples(run_dir, acc) do
    failures_root = Path.join(run_dir, "failures")
    File.mkdir_p!(failures_root)

    Enum.each(acc.samples, fn {bucket_key, entries} ->
      cond do
        entries == [] -> :ok
        bucket_key == :ok -> :ok
        bucket_key == :ok_empty_output -> :ok
        match?({:output_mismatch, _}, bucket_key) -> :ok
        match?({:python_disagrees_expected, _}, bucket_key) -> :ok
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

  # --- mismatches/<fp>/ ------------------------------------------------

  defp write_mismatch_samples(run_dir, acc) do
    mismatch_buckets =
      Enum.filter(acc.samples, fn {key, entries} ->
        entries != [] and
          (match?({:output_mismatch, _}, key) or match?({:python_disagrees_expected, _}, key))
      end)

    if mismatch_buckets != [] do
      root = Path.join(run_dir, "mismatches")
      File.mkdir_p!(root)

      Enum.each(mismatch_buckets, fn {bucket_key, entries} ->
        fp = bucket_fingerprint(bucket_key)
        bucket_dir = Path.join(root, sanitize_fp(fp))
        File.mkdir_p!(bucket_dir)

        entries
        |> Enum.with_index(1)
        |> Enum.each(fn {entry, idx} ->
          padded = String.pad_leading(Integer.to_string(idx), 3, "0")
          write_mismatch_entry(bucket_dir, padded, bucket_key, entry)
        end)
      end)
    end
  end

  defp bucket_fingerprint({:output_mismatch, fp}), do: fp
  defp bucket_fingerprint({:python_disagrees_expected, fp}), do: fp

  defp write_mismatch_entry(dir, padded, bucket_key, entry) do
    File.write!(Path.join(dir, "#{padded}.py"), entry.source)

    case entry.metadata[:elixir_source] do
      nil -> :ok
      src -> File.write!(Path.join(dir, "#{padded}.ex"), src)
    end

    per_tc = Map.get(entry.metadata, :per_testcase, [])

    File.write!(
      Path.join(dir, "#{padded}.summary.md"),
      build_testcase_summary(bucket_key, entry, per_tc)
    )

    per_tc
    |> Enum.with_index()
    |> Enum.each(fn {tc, idx} ->
      if failing_tc?(tc), do: write_testcase_artifacts(dir, padded, idx, tc)
    end)
  end

  defp failing_tc?({:ok, _}), do: false
  defp failing_tc?({:ok_empty, _}), do: false
  defp failing_tc?(_), do: true

  defp write_testcase_artifacts(dir, padded, idx, tc) do
    base = "#{padded}.testcase_#{idx}"
    meta = tc_meta(tc)

    File.write!(Path.join(dir, "#{base}.stdin.txt"), meta[:stdin] || "")
    File.write!(Path.join(dir, "#{base}.expected.txt"), meta[:expected] || "")

    case meta[:python_stdout] do
      nil -> :ok
      stdout -> File.write!(Path.join(dir, "#{base}.python.txt"), stdout)
    end

    case meta[:elixir_stdout] do
      nil -> :ok
      stdout -> File.write!(Path.join(dir, "#{base}.elixir.txt"), stdout)
    end

    case meta[:diff_summary] do
      nil -> :ok
      summary -> File.write!(Path.join(dir, "#{base}.diff"), summary)
    end
  end

  defp tc_meta({:ok, m}), do: m
  defp tc_meta({:ok_empty, m}), do: m
  defp tc_meta({:output_mismatch, _, m}), do: m
  defp tc_meta({:python_disagrees_expected, _, m}), do: m
  defp tc_meta({:elixir_runtime_error, _, m}), do: m
  defp tc_meta({:elixir_timeout, m}), do: m
  defp tc_meta({:python_failed, _, m}), do: m

  defp build_testcase_summary(bucket_key, entry, per_tc) do
    rows =
      per_tc
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {tc, idx} -> "| #{idx} | #{tc_label(tc)} |" end)

    passed = Enum.count(per_tc, fn tc -> not failing_tc?(tc) end)
    total = length(per_tc)

    """
    # sample #{entry.id}

    Bucket: `#{Bucket.slug(bucket_key)}`
    Testcases: #{passed}/#{total} passed

    | idx | outcome |
    | --- | --- |
    #{rows}
    """
  end

  defp tc_label({:ok, _}), do: ":ok"
  defp tc_label({:ok_empty, _}), do: ":ok_empty"
  defp tc_label({:output_mismatch, fp, _}), do: "{:output_mismatch, #{inspect(fp)}}"

  defp tc_label({:python_disagrees_expected, fp, _}),
    do: "{:python_disagrees_expected, #{inspect(fp)}}"

  defp tc_label({:elixir_runtime_error, mod, _}),
    do: "{:elixir_runtime_error, #{inspect(mod)}}"

  defp tc_label({:elixir_timeout, _}), do: ":elixir_timeout"

  defp tc_label({:python_failed, kind, _}),
    do: "{:python_failed, #{inspect(kind)}}"

  defp sanitize_fp(fp) do
    fp
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.slice(0, 80)
  end

  # --- ok samples ------------------------------------------------------
  #
  # `--save-ok N` populates `accumulator.samples[:ok]` (capped by N).
  # For each entry, write the Python source and the generated Elixir
  # side-by-side under `reports/<ts>/ok/`. Pair well with `mix
  # eval.show` for one-off pretty-print. Skipped silently when no OK
  # samples were collected (the default, since `--save-ok` defaults to 0).
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

        # Also write the first testcase's stdin/expected so reviewers
        # can spot-check the `:ok` claim:
        #   python3.14 reports/.../ok/001.py < ok/001.testcase_0.stdin.txt
        #     | diff - ok/001.testcase_0.expected.txt
        write_ok_first_testcase(ok_dir, padded, entry)
      end)
    end
  end

  defp write_ok_first_testcase(ok_dir, padded, entry) do
    case Map.get(entry.metadata, :per_testcase, []) do
      [first | _] ->
        meta = tc_meta(first)
        File.write!(Path.join(ok_dir, "#{padded}.testcase_0.stdin.txt"), meta[:stdin] || "")

        File.write!(
          Path.join(ok_dir, "#{padded}.testcase_0.expected.txt"),
          meta[:expected] || ""
        )

      [] ->
        :ok
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
