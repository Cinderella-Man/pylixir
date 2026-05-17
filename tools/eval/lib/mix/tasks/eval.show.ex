defmodule Mix.Tasks.Eval.Show do
  @shortdoc "Transpile a Python file and print the generated Elixir"

  @moduledoc """
  Lightweight showcase: read a Python file, transpile it via
  `Pylixir.transpile/1`, and print the result. No CPython, no
  compile-check, no stdout diff — just the lowering. Pairs well
  with `--out <file.ex>` to write the Elixir to disk.

  Compared to `mix eval.probe`:

    * `eval.probe` runs CPython + compiles + diffs stdout — full
      behavioural verification, slow, needs Python 3.14 installed.
    * `eval.show` just transpiles. Fast, useful for demos / readmes /
      pasting into chat.

  ## Usage

      mix eval.show path/to/file.py
      mix eval.show path/to/file.py --out path/to/file.ex
      mix eval.show Call/4                  # short form: latest run

  The bucket/N short form resolves the same way `eval.probe` /
  `eval.diag` do — handy for "show me the Elixir for sample 5 of the
  ok bucket" once `--save-ok` (on `eval.run`) populates it.

  ## Flags

    * `--out PATH` — write the Elixir to PATH instead of stdout.
    * `--no-source` — skip printing the Python source header (useful
      when piping the output to a file or formatter).
    * `--strip-runtime` — drop the ~2000 lines of spliced runtime
      helpers (every `def py_*` / `defp py_*` from
      `Pylixir.RuntimeHelpers`) so the output is just the user's
      `@moduledoc`, their function `@doc` + `def`s, and `py_main`.
      Pylixir-generated `while_N` helpers are kept; everything else
      that starts with `py_` is dropped.
  """

  use Mix.Task

  @switches [out: :string, no_source: :boolean, strip_runtime: :boolean]

  @impl true
  def run(argv) do
    {opts, positional} = OptionParser.parse!(argv, strict: @switches)

    file =
      case positional do
        [f] -> resolve_sample(f)
        _ -> Mix.raise("usage: mix eval.show <file.py | bucket/N> [--out PATH] [--no-source]")
      end

    unless File.exists?(file), do: Mix.raise("file not found: #{file}")

    Mix.Task.run("app.start")

    source = File.read!(file)
    elixir_src = transpile_or_die(source)
    elixir_src = if opts[:strip_runtime], do: strip_runtime(elixir_src), else: elixir_src

    case opts[:out] do
      nil -> print_to_stdout(file, source, elixir_src, opts)
      out_path -> write_to_file(out_path, elixir_src)
    end
  end

  # Drop the runtime-helper splice block from the generated source.
  # The helpers all have `py_*` names (a few exceptions like `truthy?`
  # also live in the spliced block). User-facing defs (`def foo`,
  # `defp __cls_<C>_*`, `defp while_N`, `def py_main`) are kept —
  # `py_main` is special-cased by exact match so the strip doesn't
  # also drop the user's entry point.
  defp strip_runtime(source) do
    source
    |> String.split("\n")
    |> drop_helper_blocks([])
    |> collapse_blank_runs([], 0)
    |> Enum.join("\n")
  end

  # After dropping helper bodies the gaps between them become long
  # runs of blank lines. Collapse to at most one consecutive blank
  # so the output stays scrollable.
  defp collapse_blank_runs([], acc, _), do: Enum.reverse(acc)

  defp collapse_blank_runs([line | rest], acc, blanks) do
    if String.trim(line) == "" do
      if blanks >= 1 do
        collapse_blank_runs(rest, acc, blanks + 1)
      else
        collapse_blank_runs(rest, [line | acc], blanks + 1)
      end
    else
      collapse_blank_runs(rest, [line | acc], 0)
    end
  end

  defp drop_helper_blocks([], acc), do: Enum.reverse(acc)

  defp drop_helper_blocks([line | rest], acc) do
    cond do
      runtime_def_header?(line) ->
        rest = drop_until_def_end(rest)
        drop_helper_blocks(rest, acc)

      true ->
        drop_helper_blocks(rest, [line | acc])
    end
  end

  # A line that opens a runtime-helper def. `py_main` is the user's
  # entry point — never strip it. All other helpers come from
  # `Pylixir.HelpersCodegen.helpers_ast/0`; extract every name there
  # and match against it. This catches `py_*`, `truthy?`,
  # `parse_percent_*`, `format_percent_*`, etc. without us having to
  # maintain a hardcoded list.
  @helper_names (
                  Pylixir.HelpersCodegen.helpers_ast()
                  |> Enum.flat_map(fn
                    # When-guarded clauses MUST match first; otherwise
                    # the generic pattern below binds `name = :when`
                    # and we lose the actual function name.
                    {:def, _, [{:when, _, [{name, _, _} | _]} | _]} when is_atom(name) ->
                      [Atom.to_string(name)]

                    {:defp, _, [{:when, _, [{name, _, _} | _]} | _]} when is_atom(name) ->
                      [Atom.to_string(name)]

                    {:def, _, [{name, _, _} | _]} when is_atom(name) ->
                      [Atom.to_string(name)]

                    {:defp, _, [{name, _, _} | _]} when is_atom(name) ->
                      [Atom.to_string(name)]

                    _ ->
                      []
                  end)
                  |> Enum.uniq()
                  |> Enum.reject(&(&1 in ["py_main", "when"]))
                )

  @helper_set MapSet.new(@helper_names)

  defp runtime_def_header?(line) do
    case Regex.run(~r/^\s*(?:def|defp) ([A-Za-z_][A-Za-z0-9_?!]*)/, line) do
      [_, name] -> MapSet.member?(@helper_set, name)
      _ -> false
    end
  end

  # Helper defs span from the header through the matching `  end`
  # (one-space indent matches the module-body level). Walk lines
  # until we hit a line that's just `  end`; drop it too.
  defp drop_until_def_end([]), do: []

  defp drop_until_def_end([line | rest]) do
    if Regex.match?(~r/^  end\s*$/, line) do
      rest
    else
      drop_until_def_end(rest)
    end
  end

  defp print_to_stdout(file, source, elixir_src, opts) do
    unless opts[:no_source] do
      IO.puts("# === Python source: #{file} ===")
      IO.puts(source)
      IO.puts("# === Generated Elixir ===")
    end

    IO.puts(elixir_src)
  end

  defp write_to_file(path, elixir_src) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, elixir_src)
    IO.puts("wrote #{byte_size(elixir_src)} bytes to #{path}")
  end

  defp transpile_or_die(source) do
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

  # --- path resolution (shared shape with eval.probe / eval.diag) ------

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
    ok_dir = Path.join(report_dir, "ok")

    # `eval.show` also reaches into reports/<run>/ok/ when --save-ok
    # has populated it, since the showcase workflow is exactly
    # "browse the OK pairs." Check ok/ first; fall back to failures/.
    [ok_dir, failures]
    |> Enum.flat_map(fn root ->
      case File.ls(root) do
        {:ok, names} ->
          Enum.filter(names, fn n ->
            n == bucket or String.ends_with?(n, "--" <> bucket) or
              String.contains?(n, bucket)
          end)
          |> Enum.map(&Path.join(root, &1))

        {:error, _} ->
          []
      end
    end)
    |> case do
      [match] -> match
      [] -> Mix.raise("no bucket matching `#{bucket}` under #{report_dir}")
      many -> Mix.raise("ambiguous bucket `#{bucket}`: #{Enum.join(many, ", ")}")
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
end
