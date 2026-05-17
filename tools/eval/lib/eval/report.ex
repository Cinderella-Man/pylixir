defmodule Eval.Report do
  @moduledoc """
  Persist an `Eval.run/1` accumulator to disk under
  `reports/run-<ISO8601>/`:

    * `summary.md` — human-readable per-run summary.
    * `summary.json` — machine-readable counts (for cross-run diffing).
    * `failures/<bucket-slug>/<n>.py` — first samples per bucket so
      maintainers can copy promising ones into `test/fixtures/python/`.
  """

  alias Eval.Bucket

  @doc """
  Write the report. Returns the absolute path to the run directory.
  """
  @spec write(Eval.accumulator(), keyword()) :: Path.t()
  def write(accumulator, opts \\ []) do
    run_dir = opts[:out] || default_run_dir()
    File.mkdir_p!(run_dir)

    write_json(run_dir, accumulator)
    write_markdown(run_dir, accumulator)
    write_failure_samples(run_dir, accumulator)
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

  defp write_json(run_dir, acc) do
    payload = %{
      totals: acc.totals,
      counts:
        for {key, n} <- acc.counts, into: %{} do
          {Bucket.slug(key), %{count: n, key: inspect(key)}}
        end
    }

    File.write!(Path.join(run_dir, "summary.json"), Jason.encode!(payload, pretty: true))
  end

  defp write_markdown(run_dir, acc) do
    sorted =
      acc.counts
      |> Enum.sort_by(fn {_k, n} -> -n end)

    total = acc.totals.processed
    transpiled = acc.totals.transpiled

    pct =
      if total > 0 do
        :erlang.float_to_binary(transpiled / total * 100, decimals: 1)
      else
        "0.0"
      end

    rows =
      Enum.map_join(sorted, "\n", fn {key, n} ->
        share =
          if total > 0,
            do: :erlang.float_to_binary(n / total * 100, decimals: 1),
            else: "0.0"

        "| `#{Bucket.slug(key)}` | #{n} | #{share}% |"
      end)

    body = """
    # Pylixir eval run

    | metric | value |
    | --- | --- |
    | processed | #{total} |
    | skipped (no Python extracted) | #{acc.totals.skipped} |
    | transpiled cleanly | #{transpiled} (#{pct}%) |

    ## Buckets

    | bucket | count | share |
    | --- | --- | --- |
    #{rows}

    Per-bucket failure samples are in `failures/<bucket-slug>/`.
    """

    File.write!(Path.join(run_dir, "summary.md"), body)
  end

  defp write_failure_samples(run_dir, acc) do
    failures_root = Path.join(run_dir, "failures")
    File.mkdir_p!(failures_root)

    Enum.each(acc.samples, fn {bucket_key, entries} ->
      if bucket_key != :ok and entries != [] do
        bucket_dir = Path.join(failures_root, Bucket.slug(bucket_key))
        File.mkdir_p!(bucket_dir)

        entries
        |> Enum.with_index(1)
        |> Enum.each(fn {entry, idx} ->
          padded = String.pad_leading(Integer.to_string(idx), 3, "0")
          file = Path.join(bucket_dir, "#{padded}.py")
          File.write!(file, build_sample_file(bucket_key, entry))
        end)
      end
    end)
  end

  # `--save-ok N` populates `accumulator.samples[:ok]` (capped by N).
  # For each entry, write the Python source and the generated Elixir
  # side-by-side under `reports/<ts>/ok/`. Browse the directory to see
  # real Python → Elixir pairs; pair well with `mix eval.show` for
  # one-off pretty-print. Skipped silently when no OK samples were
  # collected (the default, since `--save-ok` defaults to 0).
  defp write_ok_samples(run_dir, acc) do
    entries = Map.get(acc.samples, :ok, [])

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
