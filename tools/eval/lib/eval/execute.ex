defmodule Eval.Execute do
  @moduledoc """
  Execute the transpiled Elixir's `py_main/0` and compare its stdout to
  the dataset's verified `expected`.

  ## Elixir execution

  Invokes `module.py_main()` inside `ExUnit.CaptureIO.capture_io/2`,
  inside `Task.async/1`. When `:stdin` is supplied, it's fed to
  `capture_io` so the runtime-helper readers (`py_input/0`,
  `py_stdin_readline/0`) consume it. `Task.yield/2` enforces the
  wall-clock budget; `Task.shutdown(:brutal_kill)` aborts a hung run.
  The `{:pylixir_exit, code}` throw used by Pylixir's translated
  `sys.exit()` codegen is caught and treated as a clean exit.

  ## Output comparison

  `compare/2` normalizes both sides with **exactly** the dataset's
  canonical normalizer (`tools/dataset` `Dataset.Normalize`) before
  byte-comparing — because the shipped `expected` was produced by that
  normalizer. The rule: decode UTF-8 (latin-1 fallback) → `CRLF→LF` →
  strip per-line trailing `[ \\t]` → drop trailing blank lines + final
  newline; **leading and internal spacing is preserved**, so genuinely
  different output still differs. Mismatches carry a first-divergent-line
  fingerprint plus a human-readable summary saved to the report.

  Python is no longer executed here for comparison — the dataset's
  `expected` is the verified, deterministic CPython output.
  """

  @type elixir_result ::
          {:ok, stdout :: binary()}
          | {:raised, Exception.t() | atom()}
          | :timeout

  @type compare_result ::
          :equal
          | :equal_empty
          | {:differ, fingerprint :: String.t(), summary :: String.t()}

  # --- Public API ------------------------------------------------------

  @doc """
  Invoke `module.py_main()` and return its captured stdout. The caller is
  responsible for ensuring the module is loaded and that this is called
  from inside the `CompilePool` slot that owns its alias (so the module
  isn't purged mid-run).

  ## Options

    * `:stdin` — string fed to `module.py_main()` via
      `ExUnit.CaptureIO.capture_io(stdin, fn -> ... end)`. When `nil`
      (default), no stdin is supplied.
  """
  @spec run_elixir(module(), pos_integer(), keyword()) :: elixir_result()
  def run_elixir(module, timeout_ms, opts \\ []) do
    stdin = Keyword.get(opts, :stdin)

    task =
      Task.async(fn ->
        runner = fn ->
          try do
            module.py_main()
            :ok
          catch
            :throw, {:pylixir_exit, _code} -> :ok
          end
        end

        try do
          stdout =
            case stdin do
              nil -> ExUnit.CaptureIO.capture_io(runner)
              s when is_binary(s) -> ExUnit.CaptureIO.capture_io(s, runner)
            end

          {:ok, stdout}
        rescue
          e -> {:raised, e}
        catch
          kind, reason -> {:raised, %RuntimeError{message: "#{kind}: #{inspect(reason)}"}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> :timeout
      {:exit, reason} -> {:raised, %RuntimeError{message: inspect(reason)}}
    end
  end

  @doc """
  Compare an actual stdout against the dataset's `expected`, both
  normalized with the canonical normalizer (see moduledoc). Returns
  `:equal_empty` when both sides normalize to empty, `:equal` on a match,
  or `{:differ, fingerprint, summary}` on a mismatch.
  """
  @spec compare(String.t(), String.t()) :: compare_result()
  def compare(expected, actual) do
    e = normalize(expected)
    a = normalize(actual)

    cond do
      e == a and a == "" -> :equal_empty
      e == a -> :equal
      true -> diff(e, a)
    end
  end

  # --- Normalizer (verbatim copy of tools/dataset Dataset.Normalize) ---

  @doc """
  Canonical output normalizer — identical to the dataset's, so the
  comparison sees `expected` and the Elixir stdout on the same footing.
  """
  @spec normalize(binary()) :: String.t()
  def normalize(bin) when is_binary(bin) do
    bin
    |> to_utf8()
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(&rstrip_spaces_tabs/1)
    |> Enum.join("\n")
    |> String.trim_trailing("\n")
  end

  # Valid UTF-8 passes through; otherwise reinterpret raw bytes as latin-1
  # (every byte → a codepoint), which always yields valid UTF-8.
  defp to_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      :unicode.characters_to_binary(bin, :latin1)
    end
  end

  defp rstrip_spaces_tabs(line), do: String.replace(line, ~r/[ \t]+$/, "")

  # --- Diff / fingerprint ----------------------------------------------

  defp diff(expected, actual) do
    exp_lines = String.split(expected, "\n")
    act_lines = String.split(actual, "\n")
    {idx, e_line, a_line} = first_divergence(exp_lines, act_lines, 0)

    fp =
      case e_line do
        nil -> "missing_line"
        line -> String.slice(line, 0, 60)
      end

    summary = """
    expected: #{length(exp_lines)} lines
    actual:   #{length(act_lines)} lines
    first divergence at line #{idx + 1}:
      expected: #{snippet(e_line)}
      actual:   #{snippet(a_line)}
    """

    {:differ, fp, summary}
  end

  defp first_divergence([], [], idx), do: {idx, nil, nil}
  defp first_divergence([e | _], [], idx), do: {idx, e, nil}
  defp first_divergence([], [a | _], idx), do: {idx, nil, a}
  defp first_divergence([e | _], [a | _], idx) when e != a, do: {idx, e, a}
  defp first_divergence([_ | et], [_ | at], idx), do: first_divergence(et, at, idx + 1)

  defp snippet(nil), do: "(missing)"
  defp snippet(s), do: inspect(String.slice(s, 0, 60))
end
