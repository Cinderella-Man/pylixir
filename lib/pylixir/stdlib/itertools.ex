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

  # `itertools.combinations_with_replacement(iter, r)` — r-length
  # subsets with repetition allowed. Distinct from `combinations`
  # (which never reuses an index). Helper picks each index 0..n-1
  # then recurses including the picked index (vs combinations which
  # restricts to indices > picked).
  def call(["combinations_with_replacement"], [iter, r], _kwargs, _node),
    do: {:ok, {:py_combinations_with_replacement, [], [iter, r]}}

  def call(["permutations"], [iter], _kwargs, _node),
    do: {:ok, {:py_permutations, [], [iter]}}

  def call(["permutations"], [iter, r], _kwargs, _node),
    do: {:ok, {:py_permutations, [], [iter, r]}}

  # `itertools.product(*iters[, repeat=N])` — Cartesian product. Python
  # docs: equivalent to nested for-loops in a generator expression. Lower
  # to a runtime helper that takes a list-of-iterables; the converter
  # wraps the positional args in a list literal. `repeat` kwarg is
  # supported (`product(xs, repeat=n)` == `product(xs, xs, ..., xs)`
  # n times).
  def call(["product"], iters, kwargs, _node) when is_list(iters) do
    repeat = Map.get(kwargs, "repeat", 1)
    {:ok, {:py_product, [], [iters, repeat]}}
  end

  def call(_path, _args, _kwargs, _node), do: :no_clause

  @impl true
  def import_binding("combinations"), do: {:ok, Pylixir.Stdlib.capture(:py_combinations, 2)}

  def import_binding("combinations_with_replacement"),
    do: {:ok, Pylixir.Stdlib.capture(:py_combinations_with_replacement, 2)}
  # `permutations` is variadic (1 or 2 args). Bind the 1-arg form;
  # 2-arg calls go through stdlib_aliases-rewrite at the call site.
  def import_binding("permutations"), do: {:ok, Pylixir.Stdlib.capture(:py_permutations, 1)}

  # `from itertools import product` — bind as a 1-arg lambda over a
  # list-of-iters arg. Most call sites use the variadic positional
  # form (`product(a, b)`), which goes through the stdlib_aliases
  # rewrite that re-invokes `call/4` above with the right shape.
  def import_binding("product"),
    do:
      {:ok,
       {:fn, [],
        [
          {:->, [],
           [
             [{:iters, [], nil}],
             {:py_product, [], [{:iters, [], nil}, 1]}
           ]}
        ]}}

  def import_binding(_), do: :error
end
