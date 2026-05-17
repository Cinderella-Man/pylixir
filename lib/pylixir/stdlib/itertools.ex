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

  # `itertools.chain(*iters)` — concatenate iterables. Equivalent to
  # flat-mapping `py_iter_to_list` over the arg list, then concatenating.
  # The Pylixir call site already collects positional args into a list.
  def call(["chain"], iters, _kwargs, _node) when is_list(iters),
    do: {:ok, {:py_itertools_chain, [], [iters]}}

  # `itertools.chain.from_iterable(iter_of_iters)` — same as chain but
  # the args come as one nested iterable. The dispatch chain is
  # `chain.from_iterable(x)`: attribute `chain`, method `from_iterable`.
  # Lower to the same runtime helper, wrapping the single arg as
  # already-nested.
  def call(["chain", "from_iterable"], [iters], _kwargs, _node),
    do: {:ok, {:py_itertools_chain_from_iterable, [], [iters]}}

  # `itertools.accumulate(iter[, func])` — running totals (default `+`)
  # or running fold via `func`. Yields the running accumulator at each
  # step, INCLUDING the first elem.
  def call(["accumulate"], [iter], _kwargs, _node),
    do: {:ok, {:py_itertools_accumulate, [], [iter]}}

  def call(["accumulate"], [iter, func], _kwargs, _node),
    do: {:ok, {:py_itertools_accumulate_with, [], [iter, func]}}

  # `itertools.repeat(elem[, times])` — yield `elem` forever, or
  # `times` times if given. We only support the bounded form
  # (unbounded would require lazy streams that don't compose with
  # the rest of Pylixir's eager-list lowering).
  def call(["repeat"], [elem, times], _kwargs, _node),
    do: {:ok, {{:., [], [{:__aliases__, [], [:List]}, :duplicate]}, [], [elem, times]}}

  # `itertools.takewhile(pred, iter)` / `dropwhile(pred, iter)` — Enum
  # provides exact equivalents.
  def call(["takewhile"], [pred, iter], _kwargs, _node),
    do: {:ok, {{:., [], [{:__aliases__, [], [:Enum]}, :take_while]}, [], [iter, pred]}}

  def call(["dropwhile"], [pred, iter], _kwargs, _node),
    do: {:ok, {{:., [], [{:__aliases__, [], [:Enum]}, :drop_while]}, [], [iter, pred]}}

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

  # `itertools.groupby(iter[, key])` — group CONSECUTIVE equal (or
  # equal-under-key) elements. Returns an iterator of `(key, group)`
  # pairs. Pylixir lowers each pair to a 2-tuple so the common
  # `for k, g in groupby(xs)` shape destructures correctly. Accepts
  # `key` as either a positional 2nd arg or a `key=` kwarg (Python
  # allows both shapes).
  def call(["groupby"], [iter], kwargs, _node) do
    case Map.get(kwargs, "key") do
      nil -> {:ok, {:py_itertools_groupby, [], [iter]}}
      key_fn -> {:ok, {:py_itertools_groupby_key, [], [iter, key_fn]}}
    end
  end

  def call(["groupby"], [iter, key_fn], _kwargs, _node),
    do: {:ok, {:py_itertools_groupby_key, [], [iter, key_fn]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause

  @impl true
  def import_binding("combinations"), do: {:ok, Pylixir.Stdlib.capture(:py_combinations, 2)}

  def import_binding("combinations_with_replacement"),
    do: {:ok, Pylixir.Stdlib.capture(:py_combinations_with_replacement, 2)}

  def import_binding("chain"),
    do:
      {:ok,
       {:fn, [],
        [
          {:->, [],
           [
             [{:iters, [], nil}],
             {:py_itertools_chain, [], [{:iters, [], nil}]}
           ]}
        ]}}

  def import_binding("accumulate"),
    do: {:ok, Pylixir.Stdlib.capture(:py_itertools_accumulate, 1)}

  def import_binding("takewhile"),
    do:
      {:ok,
       {:fn, [],
        [
          {:->, [],
           [
             [{:pred, [], nil}, {:iter, [], nil}],
             {{:., [], [{:__aliases__, [], [:Enum]}, :take_while]}, [],
              [{:iter, [], nil}, {:pred, [], nil}]}
           ]}
        ]}}

  def import_binding("dropwhile"),
    do:
      {:ok,
       {:fn, [],
        [
          {:->, [],
           [
             [{:pred, [], nil}, {:iter, [], nil}],
             {{:., [], [{:__aliases__, [], [:Enum]}, :drop_while]}, [],
              [{:iter, [], nil}, {:pred, [], nil}]}
           ]}
        ]}}

  def import_binding("repeat"),
    do:
      {:ok,
       {:fn, [],
        [
          {:->, [],
           [
             [{:elem, [], nil}, {:times, [], nil}],
             {{:., [], [{:__aliases__, [], [:List]}, :duplicate]}, [],
              [{:elem, [], nil}, {:times, [], nil}]}
           ]}
        ]}}

  # `from itertools import groupby` — bind as a 1-arg lambda. The
  # 2-arg form (`groupby(xs, key)`) goes through the stdlib-alias
  # rewrite which re-invokes `call/4` above.
  def import_binding("groupby"), do: {:ok, Pylixir.Stdlib.capture(:py_itertools_groupby, 1)}
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
