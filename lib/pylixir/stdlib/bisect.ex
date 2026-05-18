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

  In-place insertion (`insort` / `insort_left` / `insort_right`) is
  recognised at the Expr clause via `statement_mutation_call/2`,
  same shape as `Pylixir.Stdlib.Heapq` — the call lowers to an
  explicit rebind of the list (`xs = py_bisect_insort(xs, v)`).
  """

  @behaviour Pylixir.Stdlib

  @insort_methods ~w(insort insort_left insort_right)

  @spec statement_mutation_call(map(), Pylixir.Context.t() | nil) ::
          {:ok, String.t(), String.t(), [map()]} | :none
  def statement_mutation_call(node, context \\ nil)

  def statement_mutation_call(
        %{
          "_type" => "Call",
          "func" => %{
            "_type" => "Attribute",
            "value" => %{"_type" => "Name", "id" => "bisect"},
            "attr" => method
          },
          "args" => [%{"_type" => "Name", "id" => name} | rest]
        },
        _context
      )
      when method in @insort_methods,
      do: {:ok, name, method, rest}

  def statement_mutation_call(
        %{
          "_type" => "Call",
          "func" => %{"_type" => "Name", "id" => alias_name},
          "args" => [%{"_type" => "Name", "id" => name} | rest]
        },
        context
      )
      when alias_name in @insort_methods do
    case context do
      nil ->
        # `ModuleAnalysis` calls us pre-stdlib-aliases. Same
        # name-heuristic as `Pylixir.Stdlib.Heapq` — false positive
        # only if the user wrote their own `insort` function, which
        # essentially never happens in real Python code.
        {:ok, name, alias_name, rest}

      _ ->
        case Map.get(context.stdlib_aliases, alias_name) do
          {"bisect", _} -> {:ok, name, alias_name, rest}
          _ -> :none
        end
    end
  end

  def statement_mutation_call(_, _), do: :none

  @impl true
  def attribute(_path, _node), do: :no_clause

  @impl true
  def call(["bisect_left"], [a, x], _kwargs, _node),
    do: {:ok, {:py_bisect_left, [], [a, x]}}

  def call(["bisect_left"], [a, x, lo], _kwargs, _node),
    do: {:ok, {:py_bisect_left, [], [a, x, lo]}}

  def call(["bisect_left"], [a, x, lo, hi], _kwargs, _node),
    do: {:ok, {:py_bisect_left, [], [a, x, lo, hi]}}

  # Python's `bisect.bisect` is an alias for `bisect_right`.
  def call(["bisect"], [a, x], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x]}}

  def call(["bisect"], [a, x, lo], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x, lo]}}

  def call(["bisect"], [a, x, lo, hi], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x, lo, hi]}}

  def call(["bisect_right"], [a, x], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x]}}

  def call(["bisect_right"], [a, x, lo], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x, lo]}}

  def call(["bisect_right"], [a, x, lo, hi], _kwargs, _node),
    do: {:ok, {:py_bisect_right, [], [a, x, lo, hi]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause

  @impl true
  def import_binding("bisect_left"), do: {:ok, Pylixir.Stdlib.capture(:py_bisect_left, 2)}
  def import_binding("bisect_right"), do: {:ok, Pylixir.Stdlib.capture(:py_bisect_right, 2)}
  # Python: `bisect.bisect` is an alias for `bisect_right`.
  def import_binding("bisect"), do: {:ok, Pylixir.Stdlib.capture(:py_bisect_right, 2)}

  # `from bisect import insort` (and variants) — the statement-form
  # `insort(xs, v)` mutates xs and is rewritten by the Expr clause
  # via `statement_mutation_call/2` (which checks stdlib_aliases for
  # the bare-Name shape). The expression-form `_ = insort(xs, v)`
  # would return nil in Python; we capture the runtime call so it
  # routes through the right helper for the rare case anyone uses
  # it as an expression (always discarded; nil-returning).
  def import_binding("insort"), do: {:ok, Pylixir.Stdlib.capture(:py_bisect_insort_right, 2)}
  def import_binding("insort_left"), do: {:ok, Pylixir.Stdlib.capture(:py_bisect_insort_left, 2)}

  def import_binding("insort_right"),
    do: {:ok, Pylixir.Stdlib.capture(:py_bisect_insort_right, 2)}

  def import_binding(_), do: :error
end
