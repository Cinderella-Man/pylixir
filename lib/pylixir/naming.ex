defmodule Pylixir.Naming do
  @moduledoc """
  Collision policy for translating Python identifiers into Elixir
  identifiers without compile errors or silent shadowing.

  ## Four categories of reserved names

  A Python identifier is **reserved** if it would either fail to compile or
  silently shadow something important when used bare in Elixir output:

    1. **Hard keywords**: the Elixir parser rejects these as variable names
       outright. (`true`, `false`, `nil`, `when`, `and`, `or`, `not`, `in`,
       `fn`, `do`, `end`, `catch`, `rescue`, `after`, `else`.)
    2. **Special-form atoms**: legal as variable names, but would shadow the
       Elixir special form in subsequent scope — and generated output uses
       most of these. (`if`, `unless`, `case`, `cond`, `for`, `receive`,
       `try`, `with`, `quote`, `unquote`, `super`, `__MODULE__`, `__DIR__`,
       `__ENV__`.)
    3. **Kernel auto-imports**: every public function and macro from
       `Kernel` is in-scope without an `import`. Shadowing one (e.g.
       Python `length = 5`) would compile, but a subsequent `length(x)`
       call would call `5.(x)` instead of `Kernel.length/1`. Derived
       programmatically via `Kernel.__info__/1` at Pylixir's compile time
       so future Kernel additions are tracked automatically.
    4. **Alias-shaped identifiers**: any identifier whose first character is
       an ASCII uppercase letter (`A`–`Z`). Elixir parses these as
       aliases (module references), not variables, so emission as a bare
       atom would either fail to compile (`Code.compile_quoted` on a
       pattern like `{W, H} = ...`) or silently match an alias literal
       instead of binding. Python idiomatically uses uppercase names for
       constants and short loop locals (`for I in ...`), so this is a
       routine collision rather than an edge case.

  A reserved name is rewritten with the `var_` prefix on emission
  (`length` → `var_length`). The original Python name lives unchanged in
  `Context.scopes`; rewriting is codegen-time only.

  ## Reserved prefix protection

  Pylixir's own emission uses two prefixes:

    * `py_*` — runtime helpers (`py_add`, `py_str`, …) and Pylixir-emitted
      wrapper functions (`py_main`).
    * `var_*` — rewritten user identifiers.

  A Python identifier matching either prefix is **rejected** at translation
  time. Without this, a Python `var_length` would collide with the
  rewritten `length`, and `py_add` would shadow Pylixir's helper.

  See [CONTEXT.md](../../CONTEXT.md) for the broader role this module
  plays in the conversion pipeline.
  """

  @hard_keywords ~w(true false nil when and or not in fn do end catch rescue after else)

  @special_forms ~w(if unless case cond for receive try with quote unquote super __MODULE__ __DIR__ __ENV__)

  @kernel_names (Kernel.__info__(:functions) ++ Kernel.__info__(:macros))
                |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)
                |> Enum.uniq()

  @reserved MapSet.new(@hard_keywords ++ @special_forms ++ @kernel_names)

  @doc """
  True if `id` collides with an Elixir hard keyword, special form, Kernel
  auto-import, or is alias-shaped (starts with ASCII `A`–`Z`). Such names
  must be rewritten with the `var_` prefix.
  """
  @spec reserved?(String.t()) :: boolean()
  def reserved?(<<c, _::binary>>) when c >= ?A and c <= ?Z, do: true
  def reserved?(id) when is_binary(id), do: MapSet.member?(@reserved, id)

  @doc """
  True if `id` would collide with Pylixir's reserved prefix space —
  `var_*` (rewritten user identifiers) or `py_*` (helpers and emitted
  wrapper functions). Identifiers matching either prefix are rejected at
  translation time.
  """
  @spec reserved_prefix?(String.t()) :: boolean()
  def reserved_prefix?("py_" <> _), do: true
  def reserved_prefix?(_), do: false

  @doc """
  Apply the `var_` prefix to `id` iff `reserved?/1` is true. User
  identifiers that themselves start with `var_` (a Python-legal name
  like `var_type`) get an extra `usr_` prefix so the emitted
  `var_var_type` doesn't collide with the rewrite of Python's
  `type` → `var_type`. Identifiers starting with `py_` are still
  outright rejected — that's our reserved runtime-helper namespace.
  """
  @spec rewrite(String.t()) :: String.t()
  def rewrite(id) when is_binary(id) do
    cond do
      # Python's throwaway names (`_`, `__`, `___`, …) — Python treats
      # these as regular variables (`for _ in xs: print(_)` is legal),
      # but Elixir's bare `_` is pattern-only and can't be used in
      # expressions. Rewrite to an underscore-prefixed valid identifier
      # (`_us`, `_us2`, ...) — readable as "underscore", silences
      # Elixir's unused-variable warning via the `_` prefix convention,
      # AND is usable as an expression. The for-loop / pattern site
      # binds the same name; reads inside the body resolve through it.
      all_underscores?(id) -> all_us_rewrite(id)
      reserved?(id) -> "var_" <> id
      String.starts_with?(id, "var_") -> "usr_" <> id
      true -> id
    end
  end

  defp all_underscores?(<<>>), do: false

  defp all_underscores?(id) when is_binary(id),
    do: id |> String.to_charlist() |> Enum.all?(&(&1 == ?_))

  defp all_us_rewrite("_"), do: "_us"
  defp all_us_rewrite(id), do: "_us" <> Integer.to_string(byte_size(id))
end
