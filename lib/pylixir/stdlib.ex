defmodule Pylixir.Stdlib do
  @moduledoc """
  Pluggable registry for Python stdlib modules Pylixir knows how to
  translate. Each registered module owns its own attribute / call
  lowerings and lives at `Pylixir.Stdlib.<Name>`. The Converter's
  `Import`, bare `Attribute`, and attribute-call clauses delegate here
  rather than pattern-matching on hardcoded module names.

  ## Adding a stdlib module

    1. Create `Pylixir.Stdlib.<Name>` and `@behaviour Pylixir.Stdlib`.
    2. Implement `attribute/2`, `call/4`, and `import_binding/1`
       (see callbacks below). `import_binding/1` can return `:error`
       for everything if your module doesn't support `from <mod> import`.
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

  @doc """
  RHS the converter binds to `<alias>` when emitting
  `from <mod> import <name> [as <alias>]`. Three common shapes:

    * value-binding (`sys.argv` → `System.argv()`): return the value AST
    * function capture (`bisect_left` → `&py_bisect_left/2`): use
      `capture/2` to build the AST
    * sentinel (e.g. heapq names that are recognised at the call site
      via `Context.stdlib_aliases`): return `{:ok, nil}` — the binding
      just reserves the name in scope

  Return `:error` for names this module doesn't expose via `from … import`.
  """
  @callback import_binding(name :: String.t()) :: {:ok, Macro.t()} | :error

  @implementations %{
    "bisect" => Pylixir.Stdlib.Bisect,
    "collections" => Pylixir.Stdlib.Collections,
    "heapq" => Pylixir.Stdlib.Heapq,
    "itertools" => Pylixir.Stdlib.Itertools,
    "math" => Pylixir.Stdlib.Math,
    "re" => Pylixir.Stdlib.Re,
    "sys" => Pylixir.Stdlib.Sys
  }

  @spec supported?(String.t()) :: boolean()
  def supported?(name), do: Map.has_key?(@implementations, name)

  @spec impl(String.t()) :: module() | nil
  def impl(name), do: Map.get(@implementations, name)

  @spec names() :: [String.t()]
  def names, do: Map.keys(@implementations) |> Enum.sort()

  @doc """
  Build a local-function capture AST (`&name/arity`). Stdlib modules
  use this to bind `from <mod> import <name>` aliases that forward to
  runtime helpers without a `mod.` prefix. The helper has to live in
  the splice (since the generated `TranslatedCode` references it
  unqualified) — the linkage test catches typos.
  """
  @spec capture(atom(), non_neg_integer()) :: Macro.t()
  def capture(name, arity) when is_atom(name) and is_integer(arity) do
    {:&, [], [{:/, [], [{name, [], nil}, arity]}]}
  end
end
