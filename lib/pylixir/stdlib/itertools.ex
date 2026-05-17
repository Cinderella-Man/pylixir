defmodule Pylixir.Stdlib.Itertools do
  @moduledoc """
  Pylixir.Stdlib implementation for a subset of Python's `itertools`.

  Currently supported:

    * `itertools.combinations(iter, r)` — every r-length subset of
      `iter` in lexicographic order. Backed by the `py_combinations/2`
      runtime helper. Returns lists rather than tuples (Python returns
      tuples; lists work equivalently for the common downstream uses).

  Not yet supported: `permutations`, `product`, `chain`, `islice`,
  `groupby`, `repeat`, `count`, `cycle`. Add a clause to `call/4`
  with the matching runtime helper to enable each.
  """

  @behaviour Pylixir.Stdlib

  @impl true
  def attribute(_path, _node), do: :no_clause

  @impl true
  def call(["combinations"], [iter, r], _kwargs, _node),
    do: {:ok, {:py_combinations, [], [iter, r]}}

  def call(["permutations"], [iter], _kwargs, _node),
    do: {:ok, {:py_permutations, [], [iter]}}

  def call(["permutations"], [iter, r], _kwargs, _node),
    do: {:ok, {:py_permutations, [], [iter, r]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause
end
