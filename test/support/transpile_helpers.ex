defmodule Pylixir.TranspileHelpers do
  @moduledoc """
  Compile-and-eval test machinery for generated Elixir source.

  Pylixir's output is a self-contained Elixir source string containing
  `defmodule TranslatedCode do ... def py_main, do: ... end` followed by
  `TranslatedCode.py_main()`. Naively compiling that string hundreds of
  times in a single `mix test` run would (a) redefine the `TranslatedCode`
  module on every call and (b) leak compile-time warnings into stdout.

  This helper:

    1. Parses the source via `Code.string_to_quoted!/1`.
    2. Rewrites `TranslatedCode` to a unique atom (`TranslatedCode_<N>`)
       so every test owns its own module — `async: true` is safe.
    3. Strips the trailing `TranslatedCode.py_main()` call from the
       parsed AST and re-issues it post-compile against the unique
       module (`<unique>.py_main()`).
    4. Wraps `Code.compile_quoted/1` in `Code.with_diagnostics/1` so the
       generated module's compile warnings are returned as structured
       data rather than printed to stderr. T05's "zero warnings"
       acceptance is enforced by asserting that list is empty.
    5. Wraps the eventual `py_main/0` invocation in
       `ExUnit.CaptureIO.capture_io/1` so any `print()`-emitted output is
       captured deterministically.

  ## Public API

    * `transpile_and_run/1` — full pipeline starting from a Python AST.
    * `transpile_and_capture/1` — thin wrapper that asserts no
      diagnostics and returns just the captured stdout.
    * `run_source/1` — test seam taking an already-emitted Elixir source
      string. Used by T04b's own acceptance suite (which lands before
      T05) so we can exercise the helper with hand-rolled output.

  ## BEAM module accumulation

  Each call to the helper compiles a new module into the BEAM module
  table. These accumulate for the lifetime of the test VM (a few MB for
  a full suite run). This is bounded and acceptable for MVP — tree-
  shaking and per-test cleanup are deferred.
  """

  import ExUnit.CaptureIO
  import ExUnit.Assertions

  @type diagnostics :: [map()]
  @type run_result ::
          {output_source :: String.t(), value :: any(), stdout :: String.t(),
           diagnostics :: diagnostics()}

  @doc """
  Full pipeline: transpile `python_ast` to Elixir source via
  `Pylixir.to_source/1`, then compile and invoke. Returns:

      {output_source, run_return_value, captured_stdout, diagnostics}
  """
  @spec transpile_and_run(map()) :: run_result()
  def transpile_and_run(python_ast) when is_map(python_ast) do
    python_ast
    |> Pylixir.to_source()
    |> run_source()
  end

  @doc """
  Convenience wrapper for tests that only care about stdout.

  Asserts `diagnostics == []` internally — if generated code produces
  compile warnings, the test fails here rather than silently passing.
  """
  @spec transpile_and_capture(map()) :: String.t()
  def transpile_and_capture(python_ast) when is_map(python_ast) do
    {_source, _value, stdout, diagnostics} = transpile_and_run(python_ast)

    assert diagnostics == [],
           "generated module produced unexpected diagnostics: " <>
             inspect(diagnostics)

    stdout
  end

  @doc """
  Test seam: run the compile-and-eval machinery on an already-emitted
  Elixir source string.

  Exposed publicly so T04b's acceptance tests can exercise the helper
  before T05's `Module`-node converter lands. Production tests should
  use `transpile_and_run/1` instead.
  """
  @spec run_source(String.t()) :: run_result()
  def run_source(source) when is_binary(source) do
    parsed = Code.string_to_quoted!(source)
    unique_alias = :"TranslatedCode_#{:erlang.unique_integer([:positive])}"

    defmodule_ast = parsed |> extract_defmodule() |> rewrite_alias(unique_alias)

    {_compile_result, diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_quoted(defmodule_ast) end)

    {value, stdout} = invoke_py_main(unique_alias)

    {source, value, stdout, diagnostics}
  end

  # --- private --------------------------------------------------------

  defp extract_defmodule({:__block__, _, statements}) do
    case Enum.filter(statements, &match?({:defmodule, _, _}, &1)) do
      [defmodule_ast] ->
        defmodule_ast

      [] ->
        raise ArgumentError, "expected a defmodule in the source; found none"

      multiple ->
        raise ArgumentError,
              "expected exactly one defmodule in the source; found #{length(multiple)}"
    end
  end

  defp extract_defmodule({:defmodule, _, _} = defmodule_ast), do: defmodule_ast

  defp extract_defmodule(other) do
    raise ArgumentError,
          "expected a defmodule or a __block__ containing one; got: #{inspect(other)}"
  end

  defp rewrite_alias(ast, unique_alias) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [:TranslatedCode]} ->
        {:__aliases__, meta, [unique_alias]}

      other ->
        other
    end)
  end

  defp invoke_py_main(unique_alias) do
    module = Module.concat(Elixir, unique_alias)
    result_key = {:pylixir_run_result, unique_alias}

    stdout =
      capture_io(fn ->
        value = module.py_main()
        Process.put(result_key, value)
      end)

    value = Process.get(result_key)
    Process.delete(result_key)

    {value, stdout}
  end
end
