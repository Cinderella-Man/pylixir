defmodule Pylixir.Stdlib.Heapq do
  @moduledoc """
  Pylixir.Stdlib implementation for Python's `heapq` module.

  Backing rep: sorted Elixir list. O(n) push/pop versus heapq's
  O(log n) — adequate for competitive-programming inputs. Heap items
  compare via Erlang's term order, which gives the right ordering for
  the dominant `(priority, vertex)` tuple shape.

  Supported:

    * `heapq.heappush(heap, item)` — statement-context only. Rebinds
      `heap` to the sorted new list via Pylixir's Expr-level Mutations
      machinery (see `Pylixir.Converter`'s Expr clause).
    * `heapq.heappop(heap)` — returns `{head, tail}`; the Assign clause
      special-cases `x = heapq.heappop(heap)` to destructure both.
    * `heapq.heapify(heap)` — statement-context only; sorts in place.

  Not yet: `heappushpop`, `heapreplace`, `nlargest`, `nsmallest`.
  """

  @behaviour Pylixir.Stdlib

  @impl true
  def attribute(_path, _node), do: :no_clause

  @impl true
  # These all return raw helper-call ASTs — the *statement-context*
  # rebind of `heap` is wired in the Converter's Expr clause (for
  # heappush/heapify) and Assign clause (for heappop).
  def call(["heappush"], [heap, item], _kwargs, _node),
    do: {:ok, {:py_heappush, [], [heap, item]}}

  def call(["heappop"], [heap], _kwargs, _node),
    do: {:ok, {:py_heappop, [], [heap]}}

  def call(["heapify"], [heap], _kwargs, _node),
    do: {:ok, {:py_heapify, [], [heap]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause
end
