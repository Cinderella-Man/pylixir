defmodule Eval.PythonCache do
  @moduledoc """
  Content-addressed cache of CPython preflight results.

  Each Python sample is content-keyed by `sha256(source)`. First time
  a sample is seen, `Eval` runs `python3` twice (for determinism) and
  caches the outcome — `ok`, `error`, `timeout`, or
  `nondeterministic`. Future runs of the same source skip Python
  entirely and go straight to the Elixir comparison.

  ## Storage

  JSONL at `tools/eval/cache/python.jsonl`. One line per entry. The
  schema field set is enumerated in `entry()`. Entries from an older
  Python version (or differing `PYTHONHASHSEED`) are ignored on load
  — they'll be re-run and overwritten.

  ## Concurrency

  An ETS table backs reads (no GenServer round-trip in the hot
  path). Writes go through the GenServer cast queue so JSONL append
  lines don't tear under concurrent puts.
  """

  use GenServer

  @name __MODULE__
  @table __MODULE__.Cache

  @type sha :: String.t()

  @type entry :: %{
          required(String.t()) => any()
        }

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

  @doc """
  Compute the cache key for a Python source string.
  """
  @spec key(String.t()) :: sha()
  def key(source) when is_binary(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end

  @doc """
  Look up a cache entry by SHA. Pure ETS read — safe to call from any
  `Task.async_stream` worker without serializing through the GenServer.
  """
  @spec lookup(sha()) :: {:hit, entry()} | :miss
  def lookup(sha) do
    case :ets.lookup(@table, sha) do
      [{^sha, entry}] -> {:hit, entry}
      [] -> :miss
    end
  end

  @doc """
  Persist a cache entry. Updates ETS synchronously then asynchronously
  appends a JSONL line. Cast so worker tasks don't block on disk I/O.
  Caller-side ETS insert means subsequent `lookup/1` calls see the entry
  immediately even if the JSONL line hasn't been flushed.
  """
  @spec put(sha(), entry()) :: :ok
  def put(sha, entry) do
    full = enrich(sha, entry)
    :ets.insert(@table, {sha, full})
    GenServer.cast(@name, {:append, full})
  end

  @doc """
  Run `python3 --version` and return the trimmed banner. Used both to
  stamp newly-written cache entries and to filter stale entries on load.
  """
  @spec current_python_version() :: String.t()
  def current_python_version do
    py = System.get_env("PYLIXIR_PYTHON") || "python3"

    case System.cmd(py, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  rescue
    ErlangError -> "unknown"
  end

  # --- GenServer -------------------------------------------------------

  @impl true
  def init(opts) do
    cache_path = Keyword.fetch!(opts, :path)
    no_cache = Keyword.get(opts, :no_cache, false)
    rebuild = Keyword.get(opts, :rebuild, false)

    python_version = current_python_version()
    hashseed = "0"

    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    :ets.insert(
      @table,
      {:__meta__, %{python_version: python_version, hashseed: hashseed}}
    )

    handle =
      if no_cache do
        nil
      else
        File.mkdir_p!(Path.dirname(cache_path))

        unless rebuild do
          load_existing(cache_path, python_version, hashseed)
        end

        mode = if rebuild, do: [:write], else: [:append]
        File.open!(cache_path, mode)
      end

    {:ok,
     %{
       cache_path: cache_path,
       no_cache: no_cache,
       handle: handle,
       python_version: python_version,
       hashseed: hashseed
     }}
  end

  @impl true
  def handle_cast({:append, _entry}, %{no_cache: true} = state),
    do: {:noreply, state}

  def handle_cast({:append, entry}, %{handle: handle} = state) do
    IO.binwrite(handle, Jason.encode!(entry) <> "\n")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{handle: nil}), do: :ok
  def terminate(_reason, %{handle: handle}), do: File.close(handle)

  # --- Internals -------------------------------------------------------

  defp enrich(sha, entry) do
    [{:__meta__, meta}] = :ets.lookup(@table, :__meta__)

    entry
    |> Map.put("sha256", sha)
    |> Map.put("python_version", meta.python_version)
    |> Map.put("hashseed", meta.hashseed)
    |> Map.put_new_lazy("created_at", fn ->
      DateTime.utc_now() |> DateTime.to_iso8601()
    end)
  end

  defp load_existing(path, current_pyver, current_hashseed) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(fn line ->
        case Jason.decode(String.trim_trailing(line)) do
          {:ok,
           %{
             "sha256" => sha,
             "python_version" => ^current_pyver,
             "hashseed" => ^current_hashseed
           } = entry} ->
            :ets.insert(@table, {sha, entry})

          _ ->
            :ok
        end
      end)
    end
  end
end
