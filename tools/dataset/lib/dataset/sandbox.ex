defmodule Dataset.Sandbox do
  @moduledoc """
  Fail-closed sandbox for bulk execution of untrusted Python. See
  docs/12_dataset-curation-plan.md §Sandboxing.

  Every python invocation is wrapped with a configurable command prefix
  (`PYLIXIR_DATASET_SANDBOX`). The default enters a **user namespace
  first** (`--user --map-root-user`) — which is what grants the
  capability to then create a loopback-only **network namespace**
  (`--net`) unprivileged — and applies `prlimit` memory/CPU caps:

      unshare --user --map-root-user --net -- prlimit --as=<bytes> --cpu=<sec> --

  Notes:

    * The plain `unshare -n` from the original sketch fails unprivileged
      (`Operation not permitted`); the userns-first form above works.
    * `--map-root-user` runs the sample as fake-uid-0 *inside the
      disposable namespace* (root only there; mapped to the real
      unprivileged uid). Standard and safe for throwaway execution.
    * `prlimit --nproc` is deliberately omitted as the primary fork
      guard (`RLIMIT_NPROC` is per-real-uid system-wide → spurious
      failures); rely on `--as` + `--cpu` + the wall-clock SIGKILL in
      `Dataset.Execute`, plus the relative output-size cap.

  `self_test!/1` is the **fail-closed gate**: it runs the prefix on a
  probe that must (a) print a sentinel and (b) fail an outbound socket.
  If either check fails — missing binary, no isolation — it raises, and
  callers must abort before processing any untrusted code.

  Tests/trusted runs set `PYLIXIR_DATASET_SANDBOX=""` (empty) to bypass
  the wrapper; they must NOT call `self_test!/1` (an empty prefix offers
  no isolation and will, correctly, fail the gate).
  """

  @as_default 2 * 1024 * 1024 * 1024
  @cpu_default 15

  @sentinel "PROBE_SENTINEL_OK"
  @net_reachable "NET_REACHABLE"
  @net_isolated "NET_ISOLATED"

  @probe """
  import socket
  print("#{@sentinel}")
  try:
      socket.create_connection(("1.1.1.1", 80), timeout=2)
      print("#{@net_reachable}")
  except Exception:
      print("#{@net_isolated}")
  """

  @doc """
  The configured sandbox command prefix string. Reads
  `PYLIXIR_DATASET_SANDBOX`; falls back to the default userns+prlimit
  incantation. Returns `""` when explicitly disabled.
  """
  @spec prefix() :: String.t()
  def prefix do
    case System.get_env("PYLIXIR_DATASET_SANDBOX") do
      nil -> default_prefix()
      explicit -> explicit
    end
  end

  @doc """
  The default sandbox prefix (userns → netns → prlimit).
  """
  @spec default_prefix(keyword()) :: String.t()
  def default_prefix(opts \\ []) do
    as = Keyword.get(opts, :as_bytes, @as_default)
    cpu = Keyword.get(opts, :cpu_seconds, @cpu_default)
    "unshare --user --map-root-user --net -- prlimit --as=#{as} --cpu=#{cpu} --"
  end

  @doc """
  True when a non-empty sandbox prefix is configured.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: String.trim(prefix()) != ""

  @doc """
  Wrap a python command string with the configured prefix. Given the
  trailing part of a shell command (e.g. `"python3.14 file.py"`), returns
  `"<prefix> python3.14 file.py"` (or the command unchanged when the
  sandbox is disabled).
  """
  @spec wrap(String.t()) :: String.t()
  def wrap(python_command) when is_binary(python_command) do
    case String.trim(prefix()) do
      "" -> python_command
      pfx -> pfx <> " " <> python_command
    end
  end

  @doc """
  Fail-closed self-test. Runs the configured prefix on a probe that
  prints a sentinel and attempts an outbound TCP connection. Returns
  `:ok` only if the probe ran **and** the network was isolated;
  otherwise raises `RuntimeError`.

  ## Options
    * `:python` — interpreter (default `Dataset.default_python/0`).
  """
  @spec self_test!(keyword()) :: :ok
  def self_test!(opts \\ []) do
    python = Keyword.get(opts, :python, Dataset.default_python())
    cmd = wrap("#{python} -c " <> sh_quote(@probe))

    {out, status} = System.cmd("sh", ["-c", "exec " <> cmd], stderr_to_stdout: true)

    cond do
      status != 0 ->
        fail("sandbox command failed (exit #{status}). prefix=#{inspect(prefix())}\n#{out}")

      not String.contains?(out, @sentinel) ->
        fail("probe did not run (no sentinel). output:\n#{out}")

      String.contains?(out, @net_reachable) ->
        fail("network is NOT isolated — sandbox unsafe. output:\n#{out}")

      String.contains?(out, @net_isolated) ->
        :ok

      true ->
        fail("unexpected probe output:\n#{out}")
    end
  rescue
    e in ErlangError ->
      fail("sandbox binary not runnable: #{Exception.message(e)}")
  end

  # --- Internals -------------------------------------------------------

  defp fail(msg), do: raise(RuntimeError, "[sandbox] fail-closed: " <> msg)

  defp sh_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
