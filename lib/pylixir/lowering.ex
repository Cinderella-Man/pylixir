defmodule Pylixir.Lowering do
  @moduledoc """
  Shared result type for any Pylixir surface that translates a single
  Python expression to an Elixir AST, plus the dispatch helper that
  turns one of those results into either `{ast, context}` or an
  `UnsupportedNodeError`.

  Two distinct surfaces produce a `result()`:

    * `Pylixir.Builtins.emit/3` — hardcoded Python builtins (`len`,
      `int`, `print`, …).
    * Every `Pylixir.Stdlib.<Module>.call/4` and `.attribute/2` —
      pluggable stdlib modules (`math`, `sys`, …).

  They are deliberately *not* unified under a shared behaviour — Builtins
  is a single hardcoded module, Stdlib is a pluggable registry, and
  conflating the two would obscure both. What they share is the **result
  type** and the dispatch helper below, so the Converter can route their
  outputs uniformly.

  ## Result conventions

    * `{:ok, ast}` — translation succeeded; `ast` lands in the generated
      module.
    * `{:error, hint}` — the symbol is recognised but its specific
      shape is known-unsupported (e.g. `math.inf` — known attribute, no
      Elixir equivalent). The Converter raises `UnsupportedNodeError`
      with this hint.
    * `:no_clause` — the implementation does not handle this path at
      all. The caller supplies a generic hint at dispatch time
      (e.g. "`sys.foo.bar` is not a supported stdlib call") because the
      implementation doesn't know enough context to write one.

  Implementations should *not* raise on unsupported shapes — that
  bypasses `Lowering.dispatch/4` and produces inconsistent diagnostics.
  Use `{:error, hint}` for known-unsupported and `:no_clause` for
  unrecognised. The dispatch helper is the only place that raises.
  """

  alias Pylixir.UnsupportedNodeError

  @type result :: {:ok, Macro.t()} | {:error, String.t()} | :no_clause

  @doc """
  Bridge a `result()` to the Converter's `{ast, context}` contract.

  `no_clause_hint` is the user-facing message raised when the lowering
  returned `:no_clause`. The caller builds it because the lowering
  implementation doesn't have enough context to (e.g. "what was the
  full dotted path?").

  `node` is the originating Python AST map — used only for the raised
  error's `node_type` / `lineno` / `col_offset` fields.
  """
  @spec dispatch(result(), String.t(), map(), context) :: {Macro.t(), context}
        when context: any()
  def dispatch({:ok, ast}, _no_clause_hint, _node, context), do: {ast, context}

  def dispatch({:error, hint}, _no_clause_hint, node, _context),
    do: raise_unsupported(node, hint)

  def dispatch(:no_clause, no_clause_hint, node, _context),
    do: raise_unsupported(node, no_clause_hint)

  defp raise_unsupported(node, hint) do
    raise UnsupportedNodeError,
      node_type: Map.fetch!(node, "_type"),
      hint: hint,
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end
end
