defmodule Pylixir.AST.Walk do
  @moduledoc """
  Scope-aware AST-walk primitive used by future tickets that need to find
  nodes within a Python AST subtree *without* descending into nested scopes.

  Boundary nodes — `walk_scope/3` visits them but does NOT recurse into their
  bodies:

    * `FunctionDef`, `AsyncFunctionDef`, `Lambda` — own variable/return scope
    * `ClassDef` — own scope
    * `ListComp`, `SetComp`, `DictComp`, `GeneratorExp` — comprehension scope

  Consumers (planned):

    * T16a — collect `assigned_vars` from a `For.body`.
    * T19 — collect top-level `FunctionDef` names from `Module.body`.
    * T20 — detect `Return` nodes inside a `FunctionDef.body`.

  The walker is pre-order: it invokes `fun` on a node *before* descending into
  the node's children. The traversal is purely additive over the accumulator —
  it never mutates the AST.
  """

  @type ast_node :: map() | list() | term()
  @type acc :: any()
  @type visitor :: (ast_node, acc -> acc)

  @boundary_types ~w(
    FunctionDef AsyncFunctionDef Lambda ClassDef
    ListComp SetComp DictComp GeneratorExp
  )

  @doc """
  Walk `node` in pre-order, invoking `fun.(node, acc)` for every visited node
  and folding the result through the accumulator.

  Boundary nodes (see `@moduledoc`) are visited themselves but their bodies
  are not traversed.
  """
  @spec walk_scope(ast_node, acc, visitor) :: acc
  def walk_scope(node, acc, fun) when is_function(fun, 2) do
    do_walk(node, acc, fun)
  end

  defp do_walk(%{"_type" => type} = node, acc, fun) do
    acc = fun.(node, acc)

    if type in @boundary_types do
      acc
    else
      node
      |> Map.delete("_type")
      |> Enum.reduce(acc, fn {_key, value}, acc -> do_walk(value, acc, fun) end)
    end
  end

  defp do_walk(list, acc, fun) when is_list(list) do
    Enum.reduce(list, acc, fn item, acc -> do_walk(item, acc, fun) end)
  end

  defp do_walk(_leaf, acc, _fun), do: acc
end
