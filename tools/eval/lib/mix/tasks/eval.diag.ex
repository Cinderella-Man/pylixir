defmodule Mix.Tasks.Eval.Diag do
  @shortdoc "Print the compile diagnostics for a sample the bucket dropped"

  @moduledoc """
  Show the actual compile-time error diagnostics for a Python sample
  whose generated Elixir failed to compile.

  The `compile_error--compile_quoted_raised` bucket is the prize bucket
  (it surfaces *silent* bugs: transpile accepted, but the emitted Elixir
  doesn't compile), but the bucket classifier only records "compile
  raised" — `Code.with_diagnostics/1` captured the real diagnostics and
  they were dropped before reaching the report. This task transpiles
  the sample again, runs the same `Code.compile_quoted/1`, and prints
  the diagnostics so the underlying cause is one command away instead
  of a 12-line `mix run -e` snippet.

  Accepts the same path forms as `mix eval.probe`:

      mix eval.diag path/to/sample.py
      mix eval.diag compile_quoted_raised/1
      mix eval.diag compile_error--compile_quoted_raised/2
  """

  use Mix.Task

  @impl true
  def run(argv) do
    file =
      case argv do
        [f] -> resolve_sample(f)
        _ -> Mix.raise("usage: mix eval.diag <file.py | bucket/N>")
      end

    unless File.exists?(file), do: Mix.raise("file not found: #{file}")

    Mix.Task.run("app.start")

    source = File.read!(file)
    elixir_src = transpile_or_die(source)
    {diags, raised} = compile_collect(elixir_src)

    errors = Enum.filter(diags, &(&1.severity == :error))
    warnings = Enum.filter(diags, &(&1.severity == :warning))

    IO.puts("# #{file}")
    IO.puts("# errors=#{length(errors)} warnings=#{length(warnings)}")

    Enum.each(errors, fn d ->
      IO.puts("ERROR #{format_position(d[:position])}: #{d.message}")
    end)

    if raised do
      IO.puts("RAISED #{inspect(raised.__struct__)}: #{Exception.message(raised)}")
    end

    if errors == [] and raised == nil do
      IO.puts("no errors — sample compiles cleanly under the current build")
    end
  end

  # --- path resolution (shared shape with eval.probe) ------------------

  defp resolve_sample(arg) do
    cond do
      File.exists?(arg) ->
        arg

      String.contains?(arg, "/") ->
        [bucket, index] = String.split(arg, "/", parts: 2)
        latest = latest_report_dir!()
        bucket_dir = match_bucket_dir!(latest, bucket)
        Path.join(bucket_dir, sample_filename!(bucket_dir, index))

      true ->
        Mix.raise("not a file and not a bucket/N shorthand: #{arg}")
    end
  end

  defp latest_report_dir! do
    case Path.wildcard("reports/run-*") |> Enum.sort() |> List.last() do
      nil -> Mix.raise("no reports/run-* directories found — run `mix eval.run` first")
      dir -> dir
    end
  end

  defp match_bucket_dir!(report_dir, bucket) do
    failures = Path.join(report_dir, "failures")

    case File.ls(failures) do
      {:ok, names} ->
        candidates =
          Enum.filter(names, fn n ->
            n == bucket or String.ends_with?(n, "--" <> bucket) or
              String.contains?(n, bucket)
          end)

        case candidates do
          [match] -> Path.join(failures, match)
          [] -> Mix.raise("no bucket matching `#{bucket}` under #{failures}")
          many -> Mix.raise("ambiguous bucket `#{bucket}`: #{Enum.join(many, ", ")}")
        end

      {:error, _} ->
        Mix.raise("no failures/ dir under #{report_dir}")
    end
  end

  defp sample_filename!(bucket_dir, index) do
    case Integer.parse(index) do
      {n, ""} when n >= 0 ->
        padded = n |> Integer.to_string() |> String.pad_leading(3, "0")
        name = padded <> ".py"

        unless File.exists?(Path.join(bucket_dir, name)),
          do: Mix.raise("no sample #{name} under #{bucket_dir}")

        name

      _ ->
        Mix.raise("expected integer sample index, got `#{index}`")
    end
  end

  # --- pipeline --------------------------------------------------------

  defp transpile_or_die(source) do
    try do
      Pylixir.transpile(source)
    rescue
      e in Pylixir.UnsupportedNodeError ->
        IO.puts(:stderr, "✗ unsupported: #{e.node_type} at line #{e.lineno || "?"}")
        if e.hint, do: IO.puts(:stderr, "  hint: #{e.hint}")
        System.halt(1)

      e in Pylixir.PythonParseError ->
        IO.puts(:stderr, "✗ parse error at line #{e.lineno || "?"}: #{e.message}")
        System.halt(1)

      e ->
        IO.puts(:stderr, "✗ transpile raised: #{inspect(e.__struct__)}")
        IO.puts(:stderr, "  #{Exception.message(e)}")
        System.halt(1)
    end
  end

  # Re-runs the same compile pipeline that `Eval.Compile.check/1` uses
  # — unique alias so concurrent invocations don't collide, and we
  # immediately delete + purge the loaded module so repeated runs in
  # the same VM don't exhaust export-table slots.
  defp compile_collect(source) do
    unique_alias = :"TranslatedCode_diag_#{:erlang.unique_integer([:positive])}"

    {raised, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          parsed = Code.string_to_quoted!(source)

          ast =
            Macro.prewalk(parsed, fn
              {:__aliases__, m, [:TranslatedCode]} -> {:__aliases__, m, [unique_alias]}
              other -> other
            end)

          defm =
            case ast do
              {:__block__, _, ss} -> Enum.find(ss, &match?({:defmodule, _, _}, &1))
              other -> other
            end

          Code.compile_quoted(defm)
          nil
        rescue
          e -> e
        end
      end)

    module = Module.concat(Elixir, unique_alias)
    :code.delete(module)
    :code.purge(module)

    {diagnostics, raised}
  end

  defp format_position({line, col}), do: "line #{line}:#{col}"
  defp format_position(line) when is_integer(line), do: "line #{line}"
  defp format_position(_), do: ""
end
