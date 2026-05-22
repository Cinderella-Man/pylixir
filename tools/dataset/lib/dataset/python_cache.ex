defmodule Dataset.PythonCache do
  @moduledoc """
  Content-addressed, resumable cache of per-`(source, stdin)` verification
  verdicts. Adapted from `Eval.PythonCache` (see
  docs/12_dataset-curation-plan.md §Resumability).

  Each `(source, stdin)` pair is keyed by
  `sha256(source <> "\\0" <> stdin)`. The cached value is the verdict of
  the whole multi-run reproducibility check (`Dataset.Verify`): the
  canonical output when reproducible, or a rejection reason. A NUL byte
  separates the two key parts so they hash unambiguously.

  Differences from the eval original:

    * No `hashseed` dimension — the curator never pins `PYTHONHASHSEED`
      (the seed varies per run by design), so it is neither stamped nor
      used to filter entries.
    * No legacy-schema cleanup (fresh project).

  Entries from a different Python version are ignored on load (outputs
  are version-sensitive). ETS backs reads; writes go through the
  GenServer so JSONL appends don't tear.
  """

  use GenServer

  @name __MODULE__
  @table __MODULE__.Cache

  @type sha :: String.t()
  @type entry :: %{required(String.t()) => any()}

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

  @doc "Cache key for a `(source, stdin)` pair."
  @spec key(String.t(), String.t()) :: sha()
  def key(source, stdin) when is_binary(source) and is_binary(stdin) do
    :crypto.hash(:sha256, source <> <<0>> <> stdin)
    |> Base.encode16(case: :lower)
  end

  @doc "Look up a verdict by key. Pure ETS read."
  @spec lookup(sha()) :: {:hit, entry()} | :miss
  def lookup(sha) do
    case :ets.lookup(@table, sha) do
      [{^sha, entry}] -> {:hit, entry}
      [] -> :miss
    end
  end

  @doc "Persist a verdict entry (ETS sync + async JSONL append)."
  @spec put(sha(), entry()) :: :ok
  def put(sha, entry) do
    full = enrich(sha, entry)
    :ets.insert(@table, {sha, full})
    GenServer.cast(@name, {:append, full})
  end

  @doc "Trimmed `python --version` banner of the configured interpreter."
  @spec current_python_version() :: String.t()
  def current_python_version do
    py = Dataset.default_python()

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

    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(@table, {:__meta__, %{python_version: python_version}})

    handle =
      if no_cache do
        nil
      else
        File.mkdir_p!(Path.dirname(cache_path))
        unless rebuild, do: load_existing(cache_path, python_version)
        File.open!(cache_path, if(rebuild, do: [:write], else: [:append]))
      end

    {:ok, %{cache_path: cache_path, no_cache: no_cache, handle: handle}}
  end

  @impl true
  def handle_cast({:append, _entry}, %{no_cache: true} = state), do: {:noreply, state}

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
    |> Map.put_new_lazy("created_at", fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
  end

  defp load_existing(path, current_pyver) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(fn line ->
        case Jason.decode(String.trim_trailing(line)) do
          {:ok, %{"sha256" => sha, "python_version" => ^current_pyver} = entry} ->
            :ets.insert(@table, {sha, entry})

          _ ->
            :ok
        end
      end)
    end
  end
end
