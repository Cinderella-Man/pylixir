defmodule Pylixir.Stdlib.Heapq do
  @moduledoc """
  Pylixir.Stdlib implementation for Python's `heapq` module.

  Backing rep: sorted Elixir list. O(n) push/pop versus heapq's
  O(log n) — adequate for competitive-programming inputs. Heap items
  compare via Erlang's term order, which gives the right ordering for
  the dominant `(priority, vertex)` tuple shape.

  ## Why this module owns extra recognizers

  heapq is the only stdlib whose calls *rebind their first argument*
  (Python documents heappush/heapify/heappop as in-place mutations).
  Pylixir's converter has to emit different shapes depending on the
  call's syntactic position (Expr statement vs Assign RHS), and the
  analysis passes need to know the rebind happens so they don't
  promote `heap = []` to a module attribute.

  Four call sites need the same recognition logic:

    * `Pylixir.Converter`'s Expr clause (heappush/heapify statement)
    * `Pylixir.Nodes.Assign` (`x = heapq.heappop(h)` destructure)
    * `Pylixir.ModuleAnalysis.mutates_name?` (don't promote)
    * `Pylixir.LoopAnalysis.names_assigned_in` (thread through loop)

  Rather than duplicate the AST pattern matches across all four,
  `statement_mutation_call/2` and `capture_return_call/2` are the
  single recognizers everyone calls. Each site still emits its own
  rebind shape — only the *recognition* is shared.

  ## Supported

    * `heapq.heappush(heap, item)` — statement-context only.
    * `heapq.heappop(heap)` — returns `{head, tail}`; the Assign
      clause destructure-binds.
    * `heapq.heapify(heap)` — statement-context only.

  Not yet: `heappushpop`, `heapreplace`, `nlargest`, `nsmallest`.
  """

  @behaviour Pylixir.Stdlib

  @impl true
  def attribute(_path, _node), do: :no_clause

  @impl true
  def call(["heappush"], [heap, item], _kwargs, _node),
    do: {:ok, {:py_heappush, [], [heap, item]}}

  def call(["heappop"], [heap], _kwargs, _node),
    do: {:ok, {:py_heappop, [], [heap]}}

  def call(["heapify"], [heap], _kwargs, _node),
    do: {:ok, {:py_heapify, [], [heap]}}

  def call(_path, _args, _kwargs, _node), do: :no_clause

  @impl true
  # heappush/heappop/heapify all rebind their heap argument. Bare
  # captures like `&py_heappush/2` wouldn't trigger that, so we bind a
  # sentinel `nil` and rely on `context.stdlib_aliases` to route
  # bare-Name calls back through the rebind path used for `heapq.X(...)`
  # (see `statement_mutation_call/2` / `capture_return_call/2` above).
  def import_binding(n) when n in ~w(heappush heappop heapify), do: {:ok, nil}
  def import_binding(_), do: :error

  # --- Shared recognizers (used by Converter / Nodes.Assign / both
  # analysis passes) ----------------------------------------------------

  @statement_methods ~w(heappush heapify)
  @capture_methods ~w(heappop)

  @doc """
  Statement-position rebind: `heapq.heappush(h, x)` / `heapq.heapify(h)`
  (or the bare-Name forms after `from heapq import …`). Returns
  `{:ok, heap_name, method, remaining_args}` or `:none`.

  When `context` is non-nil, the bare-Name shape only matches if
  `context.stdlib_aliases[name]` points at heapq — eliminates the
  false-positive risk. Analysis-time callers pass `nil` and accept the
  name-heuristic risk (false positive only if the user wrote their own
  `heappush` function, vanishingly rare in real code).
  """
  @spec statement_mutation_call(map(), Pylixir.Context.t() | nil) ::
          {:ok, String.t(), String.t(), [map()]} | :none
  def statement_mutation_call(node, context \\ nil)

  def statement_mutation_call(
        %{
          "_type" => "Call",
          "func" => %{
            "_type" => "Attribute",
            "value" => %{"_type" => "Name", "id" => "heapq"},
            "attr" => method
          },
          "args" => [%{"_type" => "Name", "id" => name} | rest]
        },
        _context
      )
      when method in @statement_methods,
      do: {:ok, name, method, rest}

  def statement_mutation_call(
        %{
          "_type" => "Call",
          "func" => %{"_type" => "Name", "id" => alias},
          "args" => [%{"_type" => "Name", "id" => name} | rest]
        },
        context
      )
      when alias in @statement_methods do
    bare_name_alias_match(alias, context, name, rest)
  end

  def statement_mutation_call(_, _), do: :none

  @doc """
  Capture-return rebind: `x = heapq.heappop(h)` (or bare-Name
  `heappop(h)`). Returns `{:ok, heap_name, "heappop", []}` or `:none`.
  Same context-vs-nil semantics as `statement_mutation_call/2`.
  """
  @spec capture_return_call(map(), Pylixir.Context.t() | nil) ::
          {:ok, String.t(), String.t(), [map()]} | :none
  def capture_return_call(node, context \\ nil)

  def capture_return_call(
        %{
          "_type" => "Call",
          "func" => %{
            "_type" => "Attribute",
            "value" => %{"_type" => "Name", "id" => "heapq"},
            "attr" => method
          },
          "args" => [%{"_type" => "Name", "id" => name} | rest]
        },
        _context
      )
      when method in @capture_methods,
      do: {:ok, name, method, rest}

  def capture_return_call(
        %{
          "_type" => "Call",
          "func" => %{"_type" => "Name", "id" => alias},
          "args" => [%{"_type" => "Name", "id" => name} | rest]
        },
        context
      )
      when alias in @capture_methods do
    bare_name_alias_match(alias, context, name, rest)
  end

  def capture_return_call(_, _), do: :none

  defp bare_name_alias_match(alias, nil, name, rest), do: {:ok, name, alias, rest}

  defp bare_name_alias_match(alias, context, name, rest) do
    case Map.get(context.stdlib_aliases || %{}, alias) do
      {"heapq", ^alias} -> {:ok, name, alias, rest}
      _ -> :none
    end
  end
end
