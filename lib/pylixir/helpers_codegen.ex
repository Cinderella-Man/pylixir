defmodule Pylixir.HelpersCodegen do
  @moduledoc """
  Reads `Pylixir.RuntimeHelpers` at *Pylixir's compile time*, extracts the
  helper block between sentinel comments, parses it into a list of Elixir
  AST nodes, and exposes them via `helpers_ast/0` for splicing into
  generated `TranslatedCode` modules (T05).

  Why this indirection: `runtime_helpers.ex` is the single source of truth
  — humans edit, ExUnit calls. The generated output must be self-contained
  (no runtime dependency on Pylixir), so we cannot `import Pylixir.RuntimeHelpers`
  — we must splice the actual helper text into the output. Reading the file
  at compile time via `@external_resource` + `File.read!` gives us the text
  once, and Elixir's compiler will rebuild Pylixir if the helper file
  changes.

  The slice approach (between sentinel comments) is intentionally text-based
  rather than AST-based — robust to additions, no need to filter `def` vs
  module attributes vs anything else inside the helpers module.
  """

  @helpers_path Path.join([__DIR__, "runtime_helpers.ex"])
  @external_resource @helpers_path

  @start_sentinel "# --- HELPERS START ---"
  @end_sentinel "# --- HELPERS END ---"

  @helpers_source (
                    raw = File.read!(@helpers_path)
                    [_before, rest] = String.split(raw, @start_sentinel, parts: 2)
                    [body, _after] = String.split(rest, @end_sentinel, parts: 2)
                    String.trim(body)
                  )

  # Parse once at compile time. Wrap in a throwaway `defmodule` so the
  # def's get a valid syntactic context (defs aren't standalone
  # expressions). Then extract the body.
  @helpers_ast (
                 wrapped =
                   "defmodule __PylixirHelpersWrap__ do\n" <>
                     @helpers_source <> "\nend"

                 {:defmodule, _, [_alias, [do: body]]} =
                   Code.string_to_quoted!(wrapped)

                 case body do
                   {:__block__, _, defs} -> defs
                   single -> [single]
                 end
               )

  @doc """
  The verbatim helper-block source text, sliced between sentinels.

  Useful for diagnostic and for tests that compile the helpers inside a
  throwaway module to confirm the slice is well-formed.
  """
  @spec helpers_source() :: String.t()
  def helpers_source, do: @helpers_source

  @doc """
  The helper block parsed into a list of `def` AST nodes, ready to splice
  into a generated `defmodule TranslatedCode do ... end` body.
  """
  @spec helpers_ast() :: [Macro.t()]
  def helpers_ast, do: @helpers_ast
end
