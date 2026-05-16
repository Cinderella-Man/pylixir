defmodule Pylixir.ControlFlow do
  @moduledoc """
  Constructors for Pylixir's throw/catch control-flow protocol.

  Three Python control-flow constructs lower to Erlang throws that an
  enclosing try/catch picks up:

    * `return value`  — throws `{:pylixir_return, value}` (only inside
      functions whose `Pylixir.Context.return_mode` is `:wrapped`).
    * `break`         — throws `{:pylixir_break, payload}` where the
      payload is the loop's accumulator pattern.
    * `continue`      — throws `{:pylixir_continue, payload}` (same
      payload convention).
    * `exit(code)` / `sys.exit(code)` — throws `{:pylixir_exit, code}`;
      `py_main`'s wrapper catches it and returns the code.

  Without this module the atoms (`:pylixir_return`, `:pylixir_break`,
  `:pylixir_continue`, `:pylixir_exit`) and tuple shapes were
  duplicated at ~10 emit sites and ~6 catch sites — any future change
  to a tuple shape (e.g. adding a source-location field for better
  diagnostics) would need synchronised edits across both files. Now
  one module owns the protocol; emitters and catchers call the
  constructors below.

  Each `throw_*/1` returns the Elixir AST for the throw expression
  (suitable as a statement). Each `catch_*/1` returns the
  `{:->, [], [pattern, body]}` clause to splice into a `catch:` list.
  """

  # --- Throw constructors (emit-side) ------------------------------------

  @doc "Throw a `return` carrying `value_ast`."
  @spec throw_return(Macro.t()) :: Macro.t()
  def throw_return(value_ast), do: {:throw, [], [{:pylixir_return, value_ast}]}

  @doc "Throw a `break` carrying the loop's accumulator `payload_ast`."
  @spec throw_break(Macro.t()) :: Macro.t()
  def throw_break(payload_ast), do: {:throw, [], [{:pylixir_break, payload_ast}]}

  @doc "Throw a `continue` carrying the loop's accumulator `payload_ast`."
  @spec throw_continue(Macro.t()) :: Macro.t()
  def throw_continue(payload_ast), do: {:throw, [], [{:pylixir_continue, payload_ast}]}

  @doc "Throw an `exit` carrying an integer exit `code_ast`."
  @spec throw_exit(Macro.t()) :: Macro.t()
  def throw_exit(code_ast), do: {:throw, [], [{:pylixir_exit, code_ast}]}

  # --- Catch-clause constructors (try/catch side) ------------------------

  @doc """
  Build the catch clause for `return`. Binds the thrown value into
  `val_pattern` (a variable reference AST) and evaluates `body_ast`.
  """
  @spec catch_return(Macro.t(), Macro.t()) :: Macro.t()
  def catch_return(val_pattern, body_ast),
    do: {:->, [], [[:throw, {:pylixir_return, val_pattern}], body_ast]}

  @doc """
  Build the catch clause for `break`. `acc_pattern` binds the thrown
  payload (the loop's accumulator); `body_ast` is the catch-arm result.
  """
  @spec catch_break(Macro.t(), Macro.t()) :: Macro.t()
  def catch_break(acc_pattern, body_ast),
    do: {:->, [], [[:throw, {:pylixir_break, acc_pattern}], body_ast]}

  @doc """
  Build the catch clause for `continue`. `acc_pattern` binds the
  thrown payload; `body_ast` is the catch-arm result (typically the
  recursive helper call or a "do nothing" expression).
  """
  @spec catch_continue(Macro.t(), Macro.t()) :: Macro.t()
  def catch_continue(acc_pattern, body_ast),
    do: {:->, [], [[:throw, {:pylixir_continue, acc_pattern}], body_ast]}

  @doc """
  Build the catch clause for `exit`. `code_pattern` binds the thrown
  code; `body_ast` is what py_main's wrapper returns.
  """
  @spec catch_exit(Macro.t(), Macro.t()) :: Macro.t()
  def catch_exit(code_pattern, body_ast),
    do: {:->, [], [[:throw, {:pylixir_exit, code_pattern}], body_ast]}
end
