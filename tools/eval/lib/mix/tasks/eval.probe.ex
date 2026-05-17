defmodule Mix.Tasks.Eval.Probe do
  @shortdoc "Run a Python file through CPython + Pylixir and diff the stdout"

  @moduledoc """
  Compress the per-loop probe-and-diagnose cycle into one command:

    1. Run the file through `python3` to capture expected stdout.
    2. Transpile via `Pylixir.transpile/1`.
    3. Compile the generated Elixir via `Eval.Compile.check/1`.
    4. Invoke `py_main/0` capturing stdout.
    5. Diff captured stdout vs CPython's; report match or differences.

  Errors at any stage are reported with the relevant detail (the
  `UnsupportedNodeError` hint + line, the first 3 compile diagnostics,
  etc.) and the task exits non-zero so it composes with shell pipelines.

  ## Usage

      mix eval.probe path/to/file.py
      mix eval.probe path/to/file.py --show

  ## Flags

    * `--show` — also print the generated Elixir module (between the
      compile and run steps) so the lowering is visible without a
      separate `mix run -e 'IO.puts(Pylixir.transpile(...))'` call.
  """

  use Mix.Task

  alias Eval.Compile

  @switches [show: :boolean]

  @impl true
  def run(argv) do
    {opts, positional} = OptionParser.parse!(argv, strict: @switches)

    file =
      case positional do
        [f] -> f
        _ -> Mix.raise("usage: mix eval.probe <file.py> [--show]")
      end

    unless File.exists?(file), do: Mix.raise("file not found: #{file}")

    Mix.Task.run("app.start")
    # ExUnit.CaptureIO is the cleanest stdout capture available without
    # spawning a sub-OS-process. ExUnit ships with Elixir; we just have
    # to start it once (autorun: false so it doesn't try to run tests).
    Application.ensure_all_started(:ex_unit)
    ExUnit.start(autorun: false)

    source = File.read!(file)

    expected = run_python(file)
    elixir_src = transpile_or_die(source)

    if opts[:show], do: print_generated(elixir_src)

    compile_or_die(elixir_src)
    actual = invoke_py_main(elixir_src)

    diff(actual, expected)
  end

  # --- pipeline stages -------------------------------------------------

  defp run_python(file) do
    case System.cmd("python3", [file], stderr_to_stdout: false) do
      {stdout, 0} ->
        stdout

      {stdout, code} ->
        IO.puts(:stderr, "python3 exited with status #{code}; partial stdout follows")
        IO.write(:stderr, stdout)
        System.halt(1)
    end
  end

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

  defp print_generated(elixir_src) do
    IO.puts("--- generated Elixir ---")
    IO.puts(elixir_src)
    IO.puts("--- end generated ---\n")
  end

  defp compile_or_die(elixir_src) do
    case Compile.check(elixir_src) do
      {:ok, diagnostics} ->
        errors = Enum.filter(diagnostics, &(&1[:severity] == :error))

        if errors == [] do
          :ok
        else
          IO.puts(:stderr, "✗ compile errors:")
          errors |> Enum.take(3) |> Enum.each(&print_diagnostic/1)
          System.halt(1)
        end

      {:error, exception} ->
        IO.puts(:stderr, "✗ compile raised: #{inspect(exception.__struct__)}")
        IO.puts(:stderr, "  #{Exception.message(exception)}")
        System.halt(1)
    end
  end

  defp print_diagnostic(%{message: msg, position: pos}) do
    IO.puts(:stderr, "  #{format_position(pos)} #{msg}")
  end

  defp format_position({line, col}), do: "line #{line}:#{col}"
  defp format_position(line) when is_integer(line), do: "line #{line}"
  defp format_position(_), do: ""

  # Invoke the generated `py_main/0` and capture its stdout. We re-parse
  # + re-compile under a fresh module alias so this run is isolated
  # from the `Compile.check/1` call above (which used a different alias
  # and discarded the compiled bytecode).
  defp invoke_py_main(elixir_src) do
    unique_alias = :"TranslatedCode_probe_#{:erlang.unique_integer([:positive])}"
    parsed = Code.string_to_quoted!(elixir_src)
    defmodule_ast = parsed |> extract_defmodule() |> rewrite_alias(unique_alias)
    Code.compile_quoted(defmodule_ast)

    module = Module.concat(Elixir, unique_alias)

    {captured, runtime_error} =
      try do
        out = ExUnit.CaptureIO.capture_io(fn -> module.py_main() end)
        {out, nil}
      rescue
        e -> {ExUnit.CaptureIO.capture_io(fn -> :ok end), e}
      end

    if runtime_error do
      IO.puts(:stderr, "✗ runtime: #{inspect(runtime_error.__struct__)}")
      IO.puts(:stderr, "  #{Exception.message(runtime_error)}")
      if captured != "", do: IO.puts(:stderr, "  partial stdout:\n#{captured}")
      System.halt(1)
    end

    captured
  end

  defp extract_defmodule({:__block__, _, statements}) do
    Enum.find(statements, &match?({:defmodule, _, _}, &1)) ||
      Mix.raise("no defmodule in generated source")
  end

  defp extract_defmodule({:defmodule, _, _} = ast), do: ast

  defp rewrite_alias(ast, unique_alias) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [:TranslatedCode]} -> {:__aliases__, meta, [unique_alias]}
      other -> other
    end)
  end

  # --- diff output -----------------------------------------------------

  defp diff(actual, expected) when actual == expected do
    IO.puts("✓ match (#{byte_size(actual)} bytes)")
  end

  defp diff(actual, expected) do
    IO.puts("✗ stdout differs")
    IO.puts("--- expected (CPython) ---")
    IO.write(expected)
    IO.puts("--- actual (Pylixir) ---")
    IO.write(actual)
    IO.puts("--- end ---")
    System.halt(1)
  end
end
