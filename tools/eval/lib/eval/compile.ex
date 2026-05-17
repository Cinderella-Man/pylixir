defmodule Eval.Compile do
  @moduledoc """
  Compile-check generated Elixir source.

  Adapted from `Pylixir.TranspileHelpers.run_source/1` in the main test
  support tree, but trimmed:

    * No invocation of `py_main/0` — v1 of the harness measures
      transpile + compile success, not behavioural equivalence.
    * No `ExUnit` dependency, so this can run from a Mix task.
    * Returns diagnostics or an exception rather than raising.

  Return shape:

    * `{:ok, diagnostics}` — `Code.compile_quoted/1` returned normally;
      `diagnostics` is whatever `Code.with_diagnostics/1` collected
      (may include warnings).
    * `{:error, exception}` — anything raised during parse / rewrite /
      compile bubbled out.
  """

  @type result ::
          {:ok, diagnostics :: [map()]}
          | {:error, Exception.t()}

  @spec check(String.t()) :: result()
  def check(source) when is_binary(source) do
    Eval.CompilePool.with_slot(fn alias_atom ->
      compile_with_alias(source, alias_atom)
    end)
  end

  defp compile_with_alias(source, alias_atom) do
    {compile_outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          parsed = Code.string_to_quoted!(source)
          defmodule_ast = parsed |> extract_defmodule() |> rewrite_alias(alias_atom)
          Code.compile_quoted(defmodule_ast)
          :ok
        rescue
          e -> {:raised, e}
        end
      end)

    # `Code.compile_quoted` loads the module as "current". To reclaim
    # its export-table slots we (a) demote it to "old" via
    # `:code.delete/1` and (b) free the old version via
    # `:code.purge/1` — the docs require this exact order.
    #
    # `Eval.CompilePool` guarantees `alias_atom` is owned by this
    # process for the duration of this call, so the next compile of
    # the same alias *replaces* this one cleanly without racing.
    # That's what keeps `export_staged_index` bounded across long
    # runs; the earlier `unique_integer`-per-call design grew the
    # index by ~330 entries per sample and crashed at ~3500.
    module = Module.concat(Elixir, alias_atom)
    :code.delete(module)
    :code.purge(module)

    case compile_outcome do
      :ok -> {:ok, diagnostics}
      {:raised, e} -> {:error, e}
    end
  end

  defp extract_defmodule({:__block__, _, statements}) do
    case Enum.filter(statements, &match?({:defmodule, _, _}, &1)) do
      [defmodule_ast] -> defmodule_ast
      [] -> raise ArgumentError, "no defmodule in generated source"
      multiple -> raise ArgumentError, "multiple defmodules: #{length(multiple)}"
    end
  end

  defp extract_defmodule({:defmodule, _, _} = ast), do: ast

  defp extract_defmodule(other),
    do: raise(ArgumentError, "unexpected top-level shape: #{inspect(other)}")

  defp rewrite_alias(ast, unique_alias) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [:TranslatedCode]} ->
        {:__aliases__, meta, [unique_alias]}

      other ->
        other
    end)
  end
end
