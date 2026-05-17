defmodule Pylixir.Stdlib.Bisect do
  @moduledoc """
  Pylixir.Stdlib implementation for Python's `bisect` module —
  insertion-point search on sorted lists.

  Currently supported:

    * `bisect.bisect_left(a, x)` / `bisect.bisect(a, x)` — leftmost
      index where `x` can be inserted to keep `a` sorted.
    * `bisect.bisect_right(a, x)` — rightmost insertion position for
      equal values.

  Pylixir lists are Elixir lists (`Enum.find_index`-backed) — O(n)
  rather than Python's true O(log n). For small / medium inputs this
  is fine; for very large sorted lists a true binary search would
  need a different backing structure.

  Not yet supported: `insort_left` / `insort_right` (in-place
  insertion — would need a depth-1 mutation-style rewrite of the
  target binding).
  """

  @behaviour Pylixir.Stdlib

  @impl true
  def attribute(_path, _node), do: :no_clause

  @impl true
  def call(["bisect_left"], [a, x], _kwargs, _node),
    do: {:ok, {:py_bisect_left, [], [a, x]}}

  def call(["bisect_left"], [a, x, lo, hi], _kwargs, _node),
    do: {:ok, {:py_bisect_left, [], [a, x, lo, hi]}}

  # Python's `bisect.bisect` is an alias for `bisect_right`.
  def call(["bisect"], [a, x], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x]}}

  def call(["bisect"], [a, x, lo, hi], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x, lo, hi]}}

  def call(["bisect_right"], [a, x], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x]}}

  def call(["bisect_right"], [a, x, lo, hi], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x, lo, hi]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause

  @impl true
  def import_binding("bisect_left"), do: {:ok, Pylixir.Stdlib.capture(:py_bisect_left, 2)}
  def import_binding("bisect_right"), do: {:ok, Pylixir.Stdlib.capture(:py_bisect_right, 2)}
  # Python: `bisect.bisect` is an alias for `bisect_right`.
  def import_binding("bisect"), do: {:ok, Pylixir.Stdlib.capture(:py_bisect_right, 2)}
  def import_binding(_), do: :error
end
