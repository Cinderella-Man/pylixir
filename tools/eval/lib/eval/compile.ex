defmodule Eval.Compile do
  @moduledoc """
  Compile generated Elixir source and execute its `py_main/0` against
  every testcase of a sample inside a single `CompilePool` slot.

  Adapted from `Pylixir.TranspileHelpers.run_source/1` in the main test
  support tree, but trimmed:

    * No `ExUnit` dependency, so this can run from a Mix task.
    * Returns diagnostics or an exception rather than raising.
    * Always runs in testcase mode — the harness now has only one mode.

  ## Slot lifetime

  One `CompilePool` slot is held across `compile → ∀ testcase: run →
  delete + purge`. The slot guarantees the alias is stable for the
  duration, so the module can't be replaced under our feet by another
  worker, and the next compile of the same alias *replaces* this one
  cleanly (see `Eval.CompilePool` for why this matters for
  `export_staged_index`).
  """

  @type result ::
          {:ok, diagnostics :: [map()]}
          | {:error, Exception.t()}

  @type testcases_result ::
          {:executed_testcases, diagnostics :: [map()], per_tc :: [any()]}
          | {:error, Exception.t()}

  @doc """
  Compile-only check. Returns `{:ok, diagnostics}` on a clean compile,
  `{:error, exception}` on parse/compile failure. The module is purged
  before this returns — callers must not assume it's loaded afterwards.

  Retained for `Mix.Tasks.Eval.Probe`, which compiles + runs in two
  separate steps. The main harness uses
  `check_and_execute_testcases/4` instead.
  """
  @spec check(String.t()) :: result()
  def check(source) when is_binary(source) do
    Eval.CompilePool.with_slot(fn alias_atom ->
      {compile_outcome, diagnostics} = do_compile(source, alias_atom)
      purge_module(alias_atom)

      case compile_outcome do
        :ok -> {:ok, diagnostics}
        {:raised, e} -> {:error, e}
      end
    end)
  end

  @doc """
  Compile `source`, then invoke `on_testcase.(module, testcase)` for
  each entry in `testcases`. Per-testcase classification is the
  caller's responsibility (the callback's return value is returned
  verbatim in the `per_tc` list).

  Returns:

    * `{:executed_testcases, diagnostics, per_tc}` — compile clean.
      `per_tc` has one entry per input `testcases`, in order.
    * `{:error, exception}` — compile itself failed; the callback was
      never invoked.

  The slot is held for the entire compile + all testcase runs + purge.
  Worst case at 16 testcases × 5 s/timeout ≈ 80 s — keep
  `:elixir_timeout` honest.
  """
  @spec check_and_execute_testcases(
          String.t(),
          [map()],
          pos_integer(),
          (module(), map() -> any())
        ) :: testcases_result()
  def check_and_execute_testcases(source, testcases, elixir_timeout_ms, on_testcase)
      when is_binary(source) and is_list(testcases) and is_integer(elixir_timeout_ms) and
             elixir_timeout_ms > 0 and is_function(on_testcase, 2) do
    Eval.CompilePool.with_slot(fn alias_atom ->
      {compile_outcome, diagnostics} = do_compile(source, alias_atom)
      module = Module.concat(Elixir, alias_atom)

      try do
        case compile_outcome do
          :ok ->
            per_tc = Enum.map(testcases, &on_testcase.(module, &1))
            {:executed_testcases, diagnostics, per_tc}

          {:raised, e} ->
            {:error, e}
        end
      after
        purge_module(alias_atom)
      end
    end)
  end

  defp do_compile(source, alias_atom) do
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
  end

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
  defp purge_module(alias_atom) do
    module = Module.concat(Elixir, alias_atom)
    :code.delete(module)
    :code.purge(module)
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
