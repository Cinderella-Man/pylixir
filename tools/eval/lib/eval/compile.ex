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
    unique_alias = :"TranslatedCode_#{:erlang.unique_integer([:positive])}"

    {compile_outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          parsed = Code.string_to_quoted!(source)
          defmodule_ast = parsed |> extract_defmodule() |> rewrite_alias(unique_alias)
          Code.compile_quoted(defmodule_ast)
          :ok
        rescue
          e -> {:raised, e}
        end
      end)

    # Every call creates a unique TranslatedCode_<N> module. Without
    # purging, after enough samples the BEAM's export-staged-index
    # fills up and the runtime crashes with:
    #   "no more index entries in export_staged_index (max=524288)"
    # observed at ~5000 samples × N internal helpers. Purge + delete
    # immediately so each iteration leaves no residue.
    module = Module.concat(Elixir, unique_alias)
    :code.purge(module)
    :code.delete(module)

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
