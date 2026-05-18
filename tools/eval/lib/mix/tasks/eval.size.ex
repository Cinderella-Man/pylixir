defmodule Mix.Tasks.Eval.Size do
  @shortdoc "Measure transpile-output byte counts across the fixture corpus"

  @moduledoc """
  Walks the fixture corpus and emits one row per fixture with the byte
  count of `Pylixir.transpile/1`'s output. Produces both a CSV for
  diff-checking and a human-readable summary (total, average, fixture
  count).

  Used as the optimization-effectiveness signal for the helper-slimming
  plan (`docs/03_helper-preamble-slimming.md`). Subsequent PRs in that
  plan must not increase the corpus average.

  ## Usage

      mix eval.size                          # walk test/fixtures/python/
      mix eval.size --slimming               # walk test/fixtures/slimming/ only
      mix eval.size --csv path/to/out.csv    # write CSV to file (otherwise stdout)
      mix eval.size --diff baseline.csv      # compare against a baseline run
      mix eval.size --no-summary             # skip the human-readable summary tail

  Exit code:
    * 0 — all fixtures transpiled cleanly.
    * 1 — at least one fixture failed to transpile (still reports the rest).
    * 2 — `--diff` mode AND any fixture has more bytes than the baseline
          (the per-PR ratchet gate).
  """

  use Mix.Task

  @switches [
    slimming: :boolean,
    csv: :string,
    diff: :string,
    no_summary: :boolean
  ]

  @default_dir "test/fixtures/python"
  @slimming_dir "test/fixtures/slimming"

  @impl true
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("app.start")

    dir = if opts[:slimming], do: @slimming_dir, else: @default_dir
    repo_root = Path.expand("../..", File.cwd!())
    abs_dir = Path.join(repo_root, dir)

    unless File.dir?(abs_dir), do: Mix.raise("fixture dir not found: #{abs_dir}")

    fixtures = list_fixtures(abs_dir)

    results =
      Enum.map(fixtures, fn path ->
        rel = Path.relative_to(path, repo_root)
        {rel, measure_one(path)}
      end)

    csv_lines = render_csv(results)

    case opts[:csv] do
      nil -> IO.puts(Enum.join(csv_lines, "\n"))
      out -> File.write!(out, Enum.join(csv_lines, "\n") <> "\n")
    end

    diff_exit =
      case opts[:diff] do
        nil -> 0
        baseline -> check_diff(results, baseline)
      end

    unless opts[:no_summary], do: print_summary(results)

    any_errors? =
      Enum.any?(results, fn
        {_, {:error, _}} -> true
        _ -> false
      end)

    exit_code =
      cond do
        diff_exit != 0 -> diff_exit
        any_errors? -> 1
        true -> 0
      end

    if exit_code != 0, do: System.halt(exit_code)
  end

  defp list_fixtures(dir) do
    dir
    |> Path.join("*.py")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp measure_one(path) do
    try do
      src = File.read!(path)
      out = Pylixir.transpile(src)
      {:ok, byte_size(out)}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, reason -> {:error, "caught #{kind}: #{inspect(reason)}"}
    end
  end

  defp render_csv(results) do
    ["path,bytes,status" | Enum.map(results, &render_row/1)]
  end

  defp render_row({path, {:ok, bytes}}), do: "#{path},#{bytes},ok"
  defp render_row({path, {:error, _}}), do: "#{path},,error"

  defp print_summary(results) do
    ok_bytes =
      for {_, {:ok, b}} <- results, do: b

    err_count = Enum.count(results, &match?({_, {:error, _}}, &1))
    n_ok = length(ok_bytes)
    total = Enum.sum(ok_bytes)
    avg = if n_ok > 0, do: div(total, n_ok), else: 0

    IO.puts("")
    IO.puts("=== Summary ===")
    IO.puts("fixtures (ok): #{n_ok}")
    IO.puts("fixtures (error): #{err_count}")
    IO.puts("total bytes: #{format_number(total)}")
    IO.puts("average bytes/fixture: #{format_number(avg)}")

    if n_ok > 0 do
      max_path =
        results
        |> Enum.filter(&match?({_, {:ok, _}}, &1))
        |> Enum.max_by(fn {_, {:ok, b}} -> b end)

      min_path =
        results
        |> Enum.filter(&match?({_, {:ok, _}}, &1))
        |> Enum.min_by(fn {_, {:ok, b}} -> b end)

      {max_p, {:ok, max_b}} = max_path
      {min_p, {:ok, min_b}} = min_path
      IO.puts("max: #{format_number(max_b)} bytes — #{max_p}")
      IO.puts("min: #{format_number(min_b)} bytes — #{min_p}")
    end
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp check_diff(results, baseline_path) do
    unless File.exists?(baseline_path), do: Mix.raise("baseline not found: #{baseline_path}")

    baseline =
      baseline_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.drop(1)
      |> Enum.flat_map(fn line ->
        case String.split(line, ",") do
          [path, bytes, "ok"] ->
            case Integer.parse(bytes) do
              {n, _} -> [{path, n}]
              _ -> []
            end

          _ ->
            []
        end
      end)
      |> Map.new()

    regressions =
      for {path, {:ok, now}} <- results,
          before = Map.get(baseline, path),
          before != nil and now > before do
        {path, before, now}
      end

    case regressions do
      [] ->
        IO.puts("\n=== Diff vs #{baseline_path}: no regressions ===")
        0

      [_ | _] ->
        IO.puts("\n=== Diff vs #{baseline_path}: REGRESSIONS ===")

        Enum.each(regressions, fn {path, before, now} ->
          IO.puts("  #{path}: #{before} → #{now} (+#{now - before})")
        end)

        2
    end
  end
end
