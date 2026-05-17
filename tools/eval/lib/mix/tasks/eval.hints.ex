defmodule Mix.Tasks.Eval.Hints do
  @shortdoc "Histogram the `hint:` lines within a report's failure samples"

  @moduledoc """
  Surface which fine-grained hints dominate a bucket so the next loop
  can target the highest-impact gap, not a random representative.

  Eval reports already have `failures/<bucket-slug>/NNN.py` files
  whose comment-prefixed metadata header carries a `hint: "..."`
  line (or two — multi-line headers wrap). This task collects those,
  collapses each hint to a short key (everything before the
  ` (allowed:` allowed-list dump, if any), counts occurrences, and
  prints a sorted histogram plus the path of the *shortest* sample
  per hint (so the cleanest repro to copy into a probe is one cd
  away).

  ## Usage

      mix eval.hints <report-dir>
      mix eval.hints <report-dir> <bucket-slug>

  ## Examples

      mix eval.hints reports/run-2026-05-17T14-22-08Z
      mix eval.hints reports/run-2026-05-17T14-22-08Z unsupported--Call
  """

  use Mix.Task

  # Cut at the start of any of these "boilerplate suffix" markers so
  # distinct hints stay distinguishable but the verbose-list bloat
  # (the attribute-methods `(allowed: ...)` dump, the stdlib-modules
  # tail) doesn't drown the actual gist in the histogram output.
  @cut_markers [" (allowed:", " (known stdlib"]

  @impl true
  def run(argv) do
    case argv do
      [report_dir] ->
        emit(report_dir, all_buckets(report_dir))

      [report_dir, bucket_slug] ->
        emit(report_dir, [Path.join([report_dir, "failures", bucket_slug])])

      _ ->
        Mix.raise("usage: mix eval.hints <report-dir> [<bucket-slug>]")
    end
  end

  defp all_buckets(report_dir) do
    failures = Path.join(report_dir, "failures")

    unless File.dir?(failures), do: Mix.raise("no failures/ dir under #{report_dir}")

    failures
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(&Path.join(failures, &1))
    |> Enum.filter(&File.dir?/1)
  end

  defp emit(_report_dir, []) do
    IO.puts("no failure buckets")
  end

  defp emit(_report_dir, bucket_dirs) do
    samples =
      Enum.flat_map(bucket_dirs, fn dir ->
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".py"))
        |> Enum.map(fn name ->
          path = Path.join(dir, name)
          {Path.basename(dir), path, File.read!(path)}
        end)
      end)

    if samples == [] do
      IO.puts("no samples in selected buckets")
    else
      histogram = build_histogram(samples)
      print_histogram(histogram, length(samples))
    end
  end

  defp build_histogram(samples) do
    samples
    |> Enum.reduce(%{}, fn {bucket, path, src}, acc ->
      key = {bucket, extract_hint_key(src)}
      sample_size = byte_size(src)

      Map.update(acc, key, %{count: 1, shortest: {sample_size, path}}, fn entry ->
        shortest =
          if sample_size < elem(entry.shortest, 0),
            do: {sample_size, path},
            else: entry.shortest

        %{count: entry.count + 1, shortest: shortest}
      end)
    end)
    |> Enum.sort_by(fn {_k, %{count: c}} -> -c end)
  end

  # Walk header comment lines, find `hint: "..."`. Hints may span
  # multiple comment-prefixed lines when the inspected metadata
  # pretty-prints. We accumulate until we see a line ending in `",`
  # or `"` (closing the JSON-ish string).
  defp extract_hint_key(src) do
    case extract_hint(src) do
      nil -> "<no hint>"
      hint -> collapse_hint(hint)
    end
  end

  defp extract_hint(src) do
    lines = String.split(src, "\n")

    # Find the start: `#   hint: "...`. Could appear on its own line
    # (pretty-printed multi-key map) or inside `# %{node_type: "X",
    # hint: "Y"}` (single-line shape, e.g. parse_error).
    Enum.find_value(lines, fn line ->
      cond do
        Regex.run(~r/^#\s+hint:\s+"(.*)"(,\s*)?$/, line) ->
          [_, body | _] = Regex.run(~r/^#\s+hint:\s+"(.*)"(,\s*)?$/, line)
          body

        Regex.run(~r/hint:\s+"([^"]*)"/, line) ->
          [_, body] = Regex.run(~r/hint:\s+"([^"]*)"/, line)
          body

        true ->
          nil
      end
    end)
  end

  defp collapse_hint(hint) do
    Enum.reduce(@cut_markers, hint, fn marker, acc ->
      case String.split(acc, marker, parts: 2) do
        [head, _] -> head
        _ -> acc
      end
    end)
  end

  defp print_histogram(histogram, total) do
    width = histogram |> Enum.map(fn {_k, %{count: c}} -> c end) |> Enum.max() |> num_width()

    IO.puts("hints across #{total} samples:\n")

    Enum.each(histogram, fn {{bucket, hint}, %{count: c, shortest: {_, path}}} ->
      IO.puts("  #{pad_left(c, width)}  #{bucket}  #{hint}")
      IO.puts("       sample: #{path}")
    end)
  end

  defp num_width(n), do: n |> Integer.to_string() |> byte_size()
  defp pad_left(n, w), do: n |> Integer.to_string() |> String.pad_leading(w)
end
