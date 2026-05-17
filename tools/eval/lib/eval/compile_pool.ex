defmodule Eval.CompilePool do
  @moduledoc """
  Bounded pool of stable module-alias slots for `Eval.Compile.check/1`.

  Why this exists: every generated `TranslatedCode_*` module splices
  ~330 runtime-helper `def`s plus its own functions. Picking a fresh
  `unique_integer`-suffixed alias per sample meant the BEAM's
  *staged-export* index grew by ~330 entries per compile. `:code.delete`
  + `:code.purge` reclaim the loaded code, but the staged-export
  entries persist until the loader stages a same-named replacement,
  and at ~1500–3500 unique modules the run crashes with:

      no more index entries in export_staged_index (max=524288)

  Throughput also degrades along the way as the index gets wider.

  The pool fixes both: a small set of stable aliases is recycled, so
  every compile of slot `k` *replaces* the prior one (cleaning the
  staged entries for that slot). A `:mutex` per slot serializes
  workers that happen to grab the same one — concurrency is preserved
  at `pool_size`, no two workers ever target the same alias
  simultaneously, and the staged-export index stays bounded.

  Pool size defaults to `System.schedulers_online() * 2` so it doesn't
  bottleneck `Task.async_stream`'s default concurrency.
  """

  use GenServer

  @name __MODULE__

  # --- Public API ------------------------------------------------------

  @doc """
  Run `fun.(alias_atom)` on a checked-out alias slot. Blocks if no slot
  is free. The slot is released when `fun` returns (success or raise).
  """
  @spec with_slot((atom() -> result)) :: result when result: any()
  def with_slot(fun) do
    alias_atom = checkout()

    try do
      fun.(alias_atom)
    after
      checkin(alias_atom)
    end
  end

  @doc false
  def start_link(opts \\ []) do
    size = opts[:size] || default_size()
    GenServer.start_link(__MODULE__, size, name: @name)
  end

  @doc """
  Idempotent boot. Mix tasks call this in `run/1` after `app.start` so
  the pool is up before `Task.async_stream` workers race to compile.
  """
  def ensure_started(opts \\ []) do
    case start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  # --- Checkout / checkin ---------------------------------------------

  defp checkout, do: GenServer.call(@name, :checkout, :infinity)
  defp checkin(alias_atom), do: GenServer.cast(@name, {:checkin, alias_atom})

  # --- GenServer -------------------------------------------------------

  @impl true
  def init(size) do
    free =
      for i <- 0..(size - 1) do
        :"TranslatedCode_pool_#{i}"
      end

    {:ok, %{free: free, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:checkout, _from, %{free: [alias_atom | rest]} = state) do
    {:reply, alias_atom, %{state | free: rest}}
  end

  def handle_call(:checkout, from, %{free: [], waiting: waiting} = state) do
    {:noreply, %{state | waiting: :queue.in(from, waiting)}}
  end

  @impl true
  def handle_cast({:checkin, alias_atom}, %{waiting: waiting} = state) do
    case :queue.out(waiting) do
      {{:value, from}, rest} ->
        GenServer.reply(from, alias_atom)
        {:noreply, %{state | waiting: rest}}

      {:empty, _} ->
        {:noreply, %{state | free: [alias_atom | state.free]}}
    end
  end

  defp default_size, do: System.schedulers_online() * 2
end
