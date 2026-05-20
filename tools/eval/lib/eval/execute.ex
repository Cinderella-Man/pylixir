defmodule Eval.Execute do
  @moduledoc """
  Execute a Python source via the CPython binary, execute the
  transpiled Elixir's `py_main/0`, and compare their stdout.

  ## Python execution

  Spawns `python3` (resolved via `PYLIXIR_PYTHON`, default `python3`)
  through `sh -c` so we can redirect stdin from `/dev/null`. On
  timeout the direct child PID is SIGKILL'd. Process descendants
  spawned by the sample (rare in this corpus) may briefly leak
  before BEAM exit reaps them.

  ## Elixir execution

  Invokes `module.py_main()` inside `ExUnit.CaptureIO.capture_io/1`,
  inside `Task.async/1`. `Task.yield/2` enforces the wall-clock
  budget; `Task.shutdown(:brutal_kill)` aborts a hung run. The
  `{:pylixir_exit, code}` throw used by Pylixir's translated
  `sys.exit()` codegen (see `lib/pylixir/converter.ex:3038-3041`) is
  caught and treated as a clean exit.

  ## Output comparison

  Strict byte-equal after `\\r\\n → \\n` normalization. Mismatches
  carry a first-divergent-line fingerprint plus a human-readable
  summary string saved to the report.
  """

  # `Port.open(... env: ...)` requires charlists, not binaries, on the
  # current Erlang/OTP. Binary values raise `ArgumentError: invalid
  # option in list`.
  @python_env [
    {~c"PYTHONHASHSEED", ~c"0"},
    {~c"PYTHONWARNINGS", ~c"ignore"}
  ]

  @type python_result ::
          {:ok, stdout :: binary()}
          | {:exit, status :: non_neg_integer(), output :: binary()}
          | :timeout

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
  Run `source` under CPython with stdin from `/dev/null` and
  PYTHONHASHSEED=0. Returns `{:ok, stdout}` on a 0 exit, `{:exit,
  status, output}` on a non-zero exit (stdout+stderr combined), or
  `:timeout` if it exceeded `:timeout_ms`.
  """
  @spec run_python(String.t(), keyword()) :: python_result()
  def run_python(source, opts) when is_binary(source) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    tmp = tmp_path()

    try do
      File.mkdir_p!(Path.dirname(tmp))
      File.write!(tmp, source)
      do_run_python(tmp, timeout_ms)
    after
      File.rm(tmp)
    end
  end

  @doc """
  Invoke `module.py_main()` and return its captured stdout. The
  caller is responsible for ensuring the module is loaded and that
  this is called from inside the `CompilePool` slot that owns its
  alias (so the module isn't purged mid-run).
  """
  @spec run_elixir(module(), pos_integer()) :: elixir_result()
  def run_elixir(module, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          stdout =
            ExUnit.CaptureIO.capture_io(fn ->
              try do
                module.py_main()
                :ok
              catch
                :throw, {:pylixir_exit, _code} -> :ok
              end
            end)

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
  Compare two stdout strings byte-equal after `\\r\\n → \\n`
  normalization. Returns `:equal_empty` when both sides are empty
  (after trimming trailing newlines), `:equal` otherwise on a match,
  or `{:differ, fingerprint, summary}` on a mismatch.
  """
  @spec compare_outputs(String.t(), String.t()) :: compare_result()
  def compare_outputs(python_stdout, elixir_stdout) do
    p = normalize(python_stdout)
    e = normalize(elixir_stdout)

    cond do
      p == e and empty?(p) -> :equal_empty
      p == e -> :equal
      true -> diff(p, e)
    end
  end

  # --- Internals -------------------------------------------------------

  defp do_run_python(tmp, timeout_ms) do
    sh = find_executable!("sh")
    py = python_cmd()

    cmd = "exec " <> sh_quote(py) <> " " <> sh_quote(tmp) <> " < /dev/null"

    port =
      Port.open(
        {:spawn_executable, sh},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: ["-c", cmd],
          env: @python_env
        ]
      )

    drain_port(port, timeout_ms, [])
  end

  defp drain_port(port, timeout_ms, acc) do
    receive do
      {^port, {:data, data}} ->
        drain_port(port, timeout_ms, [acc, data])

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, status}} ->
        {:exit, status, IO.iodata_to_binary(acc)}
    after
      timeout_ms ->
        kill_port(port)
        :timeout
    end
  end

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    drain_remaining_messages(port)
  end

  defp drain_remaining_messages(port) do
    receive do
      {^port, _} -> drain_remaining_messages(port)
    after
      50 -> :ok
    end
  end

  defp python_cmd, do: System.get_env("PYLIXIR_PYTHON") || "python3"

  defp tmp_path do
    base = Path.expand("../../tmp", __DIR__)
    unique = :erlang.unique_integer([:positive])
    Path.join(base, "py_exec_#{System.system_time(:millisecond)}_#{unique}.py")
  end

  defp find_executable!(name) do
    case System.find_executable(name) do
      nil -> raise "executable not found on PATH: #{name}"
      path -> path
    end
  end

  defp sh_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp normalize(s), do: String.replace(s, "\r\n", "\n")

  defp empty?(s), do: String.trim_trailing(s, "\n") == ""

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
