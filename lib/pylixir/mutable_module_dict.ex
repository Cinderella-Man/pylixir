defmodule Pylixir.MutableModuleDict do
  @moduledoc """
  Process-dict adapter for module-level mutable bindings — the lowering
  shape Pylixir uses when a top-level Python name is mutated inside a
  function (the `memo = {}; def f(k): memo[k] = …; memo` pattern). See
  `CONTEXT.md` → "Module attrs" and `ModuleAnalysis.mutable_module_dicts`
  for who decides which names get this treatment.

  Reads/writes go through Erlang's process dictionary under the
  namespaced key `{:pylixir_mod, name}` so they don't collide with any
  process-dict slot the user's own code might touch. The `:pylixir_mod`
  tag lives in this module exactly once; without that, the namespacing
  would have to stay synchronised across multiple Converter and Assign
  sites.

  Two adapters, one seam: this module is called from `Pylixir.Converter`
  (Name read clause, AugAssign on a Name) and `Pylixir.Nodes.Assign`
  (Subscript-Assign to a mutable dict, plain Name re-assign).
  """

  @doc """
  Build the `Process.get({:pylixir_mod, name})` AST.

  Used at every read site for a name registered in
  `Context.mutable_module_dicts`.
  """
  @spec get_ast(String.t()) :: Macro.t()
  def get_ast(name) do
    key = namespaced_key(name)
    {{:., [], [{:__aliases__, [], [:Process]}, :get]}, [], [key]}
  end

  @doc """
  Build the `Process.put({:pylixir_mod, name}, value_ast)` AST.

  Used at every write site (Assign, AugAssign, Subscript-Assign) for a
  name registered in `Context.mutable_module_dicts`.
  """
  @spec put_ast(String.t(), Macro.t()) :: Macro.t()
  def put_ast(name, value_ast) do
    key = namespaced_key(name)
    {{:., [], [{:__aliases__, [], [:Process]}, :put]}, [], [key, value_ast]}
  end

  # Single source of truth for the namespacing tag. Changing this
  # value (or the key shape) is a one-file edit.
  defp namespaced_key(name), do: {:{}, [], [:pylixir_mod, name]}
end
