defmodule Eval.TraceCache do
  @moduledoc """
  Side-car cache of CPython tracer envelopes (docs/09 step 8.1). Keyed by
  `key/2` = `sha256(source <> "\\0" <> stdin)`, so a `(source, stdin)`
  pair maps to its trace envelope without re-running the tracer.

  ## Storage

  JSONL at `tools/eval/cache/python_traces.jsonl`. One line per entry,
  shape:

      {"sha256": "...", "envelope": {...}, "python_version": "...",
       "created_at": "..."}

  Older `python.jsonl` entries (pre-trace world) continue to serve
  stdout lookups unchanged. Misses on this cache trigger a fresh tracer
  run; entries are written lazily on first hit.

  ## Concurrency

  ETS-backed reads (no GenServer round-trip in the hot path). Writes
  go through `handle_cast`.
  """

  use GenServer

  @name __MODULE__
  @table __MODULE__.Cache

  @type sha :: String.t()
  @type envelope :: map()

  # --- Public API ------------------------------------------------------

  def ensure_started(opts) do
    case start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Cache key for a `(source, stdin)` pair: `sha256(source <> 0 <> stdin)`."
  @spec key(String.t(), String.t()) :: sha()
  def key(source, stdin) when is_binary(source) and is_binary(stdin) do
    :crypto.hash(:sha256, source <> <<0>> <> stdin)
    |> Base.encode16(case: :lower)
  end

  @spec lookup(sha()) :: {:hit, envelope()} | :miss
  def lookup(sha) do
    case :ets.lookup(@table, sha) do
      [{^sha, envelope}] -> {:hit, envelope}
      [] -> :miss
    end
  rescue
    ArgumentError ->
      # Table not yet started (test path without TraceCache.ensure_started).
      :miss
  end

  @spec put(sha(), envelope()) :: :ok
  def put(sha, envelope) do
    :ets.insert(@table, {sha, envelope})
    GenServer.cast(@name, {:append, sha, envelope})
  rescue
    ArgumentError -> :ok
  end

  # --- GenServer -------------------------------------------------------

  @impl true
  def init(opts) do
    cache_path = Keyword.fetch!(opts, :path)
    no_cache = Keyword.get(opts, :no_cache, false)

    python_version = current_python_version()

    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    :ets.insert(@table, {:__meta__, %{python_version: python_version}})

    handle =
      if no_cache do
        nil
      else
        File.mkdir_p!(Path.dirname(cache_path))
        load_existing(cache_path, python_version)
        File.open!(cache_path, [:append])
      end

    {:ok,
     %{
       cache_path: cache_path,
       no_cache: no_cache,
       handle: handle,
       python_version: python_version
     }}
  end

  @impl true
  def handle_cast({:append, _sha, _envelope}, %{no_cache: true} = state),
    do: {:noreply, state}

  def handle_cast({:append, sha, envelope}, %{handle: handle, python_version: pyver} = state) do
    line = %{
      "sha256" => sha,
      "envelope" => envelope,
      "python_version" => pyver,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    IO.binwrite(handle, Jason.encode!(line) <> "\n")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{handle: nil}), do: :ok
  def terminate(_reason, %{handle: handle}), do: File.close(handle)

  # --- Internals -------------------------------------------------------

  defp current_python_version do
    py = System.get_env("PYLIXIR_PYTHON") || "python3"

    case System.cmd(py, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  rescue
    ErlangError -> "unknown"
  end

  defp load_existing(path, current_pyver) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(fn line ->
        case Jason.decode(String.trim_trailing(line)) do
          {:ok,
           %{
             "sha256" => sha,
             "envelope" => envelope,
             "python_version" => ^current_pyver
           }} ->
            :ets.insert(@table, {sha, envelope})

          _ ->
            :ok
        end
      end)
    end
  end
end
