defmodule Pylixir.Stdlib do
  @moduledoc """
  Pluggable registry for Python stdlib modules Pylixir knows how to
  translate. Each registered module owns its own attribute / call
  lowerings and lives at `Pylixir.Stdlib.<Name>`. The Converter's
  `Import`, bare `Attribute`, and attribute-call clauses delegate here
  rather than pattern-matching on hardcoded module names.

  ## Adding a stdlib module

    1. Create `Pylixir.Stdlib.<Name>` and `@behaviour Pylixir.Stdlib`.
    2. Implement `attribute/2` and `call/3` (see callbacks below).
    3. Add the `"name" => Module` entry to `@implementations`.

  No other code changes needed — `Converter` discovers new entries via
  `supported?/1` and `impl/1`.

  ## Path convention

  Both callbacks receive an `attr_path` that is the list of attribute
  names *after* the module name:

    * `math.pi`           — `attribute(["pi"], node)`
    * `math.sqrt(4)`      — `call(["sqrt"], [4_ast], node)`
    * `sys.stdin.read()`  — `call(["stdin", "read"], [], node)`

  Path length is always ≥ 1. Single-segment paths cover flat modules
  (math); multi-segment paths cover chained access (sys.stdin.read).

  ## Return convention

  Both callbacks return a `Pylixir.Lowering.result()` — see that module
  for the full contract. Implementations should not raise on
  unsupported shapes; return `{:error, hint}` or `:no_clause` instead.
  """

  @type attr_path :: [String.t(), ...]

  @callback attribute(attr_path(), node :: map()) :: Pylixir.Lowering.result()
  @callback call(
              attr_path(),
              args :: [Macro.t()],
              kwargs :: %{optional(String.t()) => Macro.t()},
              node :: map()
            ) :: Pylixir.Lowering.result()

  @implementations %{
    "math" => Pylixir.Stdlib.Math,
    "sys" => Pylixir.Stdlib.Sys
  }

  @spec supported?(String.t()) :: boolean()
  def supported?(name), do: Map.has_key?(@implementations, name)

  @spec impl(String.t()) :: module() | nil
  def impl(name), do: Map.get(@implementations, name)

  @spec names() :: [String.t()]
  def names, do: Map.keys(@implementations) |> Enum.sort()
end
