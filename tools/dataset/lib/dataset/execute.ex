defmodule Dataset.Execute do
  @moduledoc """
  Execute untrusted Python via CPython, under the sandbox, capturing
  stdout. Adapted from `Eval.Execute` — trimmed to the python path only
  (the curator never runs Elixir), with three deliberate changes from the
  eval original (see docs/12_dataset-curation-plan.md):

    1. **`PYTHONHASHSEED` is NOT pinned.** Eval pinned it to `"0"`; here
       it's left unset so each process draws a fresh random hash seed.
       This is load-bearing: repeated runs of the same program then
       expose set/dict iteration-order nondeterminism (the verifier runs
       a program 5× and drops it if outputs vary). Re-pinning the seed
       would make hash-ordering invisible.
    2. **Sandboxed.** The invocation is wrapped with `Dataset.Sandbox`'s
       prefix (userns → netns → prlimit). Callers must have run
       `Dataset.Sandbox.self_test!/1` first (fail-closed).
    3. **Relative output-size cap.** `:output_cap` bytes; if accumulated
       stdout exceeds it the child is SIGKILL'd and `:output_exceeded`
       returned (`prlimit --fsize` can't cap a pipe). Callers pass
       `len(expected) + 1 MB`.

  Stdin is redirected from a per-call `.stdin` tmp file (when supplied)
  or `/dev/null`. On timeout the child is SIGKILL'd.

  Each run executes in a **fresh per-call working directory** that is
  removed afterward, so a solution that writes relative output files
  (`open("out.txt", "w")`) litters the throwaway dir, not the project
  tree. The sandbox isolates network/resources but not the filesystem, so
  this cwd hop is what contains stray writes.
  """

  alias Dataset.Sandbox

  # `Port.open(... env: ...)` requires charlists, not binaries. Note the
  # absence of `PYTHONHASHSEED` — see moduledoc point (1).
  @python_env [
    {~c"PYTHONWARNINGS", ~c"ignore"}
  ]

  @type python_result ::
          {:ok, stdout :: binary()}
          | {:exit, status :: non_neg_integer(), output :: binary()}
          | :timeout
          | :output_exceeded

  @doc """
  Run `source` under sandboxed CPython. Returns `{:ok, stdout}` on a 0
  exit, `{:exit, status, output}` on non-zero (stdout+stderr combined),
  `:timeout` past `:timeout_ms`, or `:output_exceeded` past `:output_cap`.

  ## Options

    * `:timeout_ms` (required) — wall-clock budget.
    * `:stdin` — string content fed on stdin (default: `/dev/null`).
    * `:output_cap` — max stdout bytes before abort (default: unlimited).
    * `:python` — interpreter (default `Dataset.default_python/0`).
  """
  @spec run_python(String.t(), keyword()) :: python_result()
  def run_python(source, opts) when is_binary(source) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    stdin = Keyword.get(opts, :stdin)
    output_cap = Keyword.get(opts, :output_cap)
    python = Keyword.get(opts, :python, Dataset.default_python())

    workdir = work_dir()
    script = Path.join(workdir, "main.py")
    stdin_path = if stdin, do: Path.join(workdir, "stdin"), else: nil

    try do
      File.mkdir_p!(workdir)
      File.write!(script, source)
      if stdin_path, do: File.write!(stdin_path, stdin)
      do_run_python(python, script, stdin_path, workdir, timeout_ms, output_cap)
    after
      # Removes the script, stdin, and any files the solution wrote.
      File.rm_rf(workdir)
    end
  end

  # --- Internals -------------------------------------------------------

  defp do_run_python(python, script, stdin_path, workdir, timeout_ms, output_cap) do
    sh = find_executable!("sh")

    redirect = if stdin_path, do: sh_quote(stdin_path), else: "/dev/null"
    inner = Sandbox.wrap(sh_quote(python) <> " " <> sh_quote(script))
    cmd = "exec " <> inner <> " < " <> redirect

    port =
      Port.open(
        {:spawn_executable, sh},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          # Run in the throwaway workdir so relative file writes by the
          # untrusted solution stay contained (paths above are absolute).
          {:cd, workdir},
          args: ["-c", cmd],
          env: @python_env
        ]
      )

    drain_port(port, timeout_ms, [], 0, output_cap)
  end

  defp drain_port(port, timeout_ms, acc, size, cap) do
    receive do
      {^port, {:data, data}} ->
        new_size = size + byte_size(data)

        if is_integer(cap) and new_size > cap do
          kill_port(port)
          :output_exceeded
        else
          drain_port(port, timeout_ms, [acc, data], new_size, cap)
        end

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

  defp work_dir do
    base = Path.expand("../../tmp", __DIR__)
    unique = :erlang.unique_integer([:positive])
    Path.join(base, "py_exec_#{System.system_time(:millisecond)}_#{unique}")
  end

  defp find_executable!(name) do
    case System.find_executable(name) do
      nil -> raise "executable not found on PATH: #{name}"
      path -> path
    end
  end

  defp sh_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
