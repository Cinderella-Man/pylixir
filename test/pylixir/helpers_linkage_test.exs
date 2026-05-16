defmodule Pylixir.HelpersLinkageTest do
  @moduledoc """
  Compile-time link check: every `py_*` reference emitted by a Pylixir
  Lowering producer (`Pylixir.Builtins` or any `Pylixir.Stdlib` impl)
  must resolve to a real helper in `Pylixir.RuntimeHelpers`.

  The risk this catches: a lowering returns `{:ok, {:py_renamed, [], …}}`
  but the helper got renamed (or was never added). The transpile + parse
  + compile pipeline succeeds, the test suite passes, and the bad
  reference only surfaces at *user* runtime when the generated module is
  loaded and called. The static walk below fails next to the rename
  instead.

  Static-walk approach: parse each producer's source file, prewalk for
  `{:{}, _, [atom, [], args]}` shapes (3-tuple LITERALS that look like
  the standard Elixir-call AST shape `{name, meta, args}`), keep only
  those whose first atom starts with `py_`, and assert each
  `{name, length(args)}` is in `HelpersCodegen.helper_names/0`.

  Why the `:{}` wrapping: 3-tuple literals in source parse to
  `{:{}, _, elements}` because the raw 3-tuple shape is reserved for
  call AST nodes themselves. So a source line
  `{:py_int, [], [x]}` becomes `{:{}, _, [:py_int, [], [{:x, _, _}]]}`
  at parse time — exactly what we walk for.

  Limitation: only `py_*` prefixed references are checked, and only
  static tuple literals (not references built from a dynamic name like
  `{fn_atom, [], args}`). The convention in CONTEXT.md (the Helper
  entry) is that `py_*` is the public emission prefix, so this is the
  load-bearing namespace. Dynamic emissions are rare enough that a
  per-clause unit test catches them.
  """
  use ExUnit.Case, async: true

  alias Pylixir.{HelpersCodegen, Stdlib}

  @repo_root Path.expand("../..", __DIR__)

  defp source_path(mod) do
    relative =
      mod
      |> Atom.to_string()
      |> String.replace_prefix("Elixir.", "")
      |> Macro.underscore()

    Path.join([@repo_root, "lib", relative <> ".ex"])
  end

  # All Pylixir modules that emit Elixir-AST tuples for splicing into
  # generated `TranslatedCode` — Builtins, every Stdlib impl, and the
  # Converter itself (which emits the bulk of py_* references like
  # py_setitem / py_getitem / py_mult). New Stdlib impls are picked up
  # automatically via the registry; new emit sites in Converter or
  # Builtins are picked up because the walk is over the source file.
  defp producer_modules do
    stdlib_impls = Enum.map(Stdlib.names(), &Stdlib.impl/1)
    [Pylixir.Builtins, Pylixir.Converter | stdlib_impls]
  end

  defp collect_py_refs(ast) do
    {_, refs} =
      Macro.prewalk(ast, [], fn
        {:{}, _meta, [name, [], args]} = node, acc
        when is_atom(name) and is_list(args) ->
          if String.starts_with?(Atom.to_string(name), "py_") do
            {node, [{name, length(args)} | acc]}
          else
            {node, acc}
          end

        other, acc ->
          {other, acc}
      end)

    refs
  end

  describe "py_* references in Lowering producers" do
    test "every py_* call emitted by Builtins or Stdlib impls resolves to a real helper" do
      helpers = HelpersCodegen.helper_names()

      bad =
        for mod <- producer_modules(),
            path = source_path(mod),
            File.exists?(path),
            ast = path |> File.read!() |> Code.string_to_quoted!(),
            {name, arity} <- collect_py_refs(ast),
            not MapSet.member?(helpers, {name, arity}),
            uniq: true do
          {mod, name, arity}
        end

      assert bad == [],
             "py_* references with no matching helper:\n" <>
               Enum.map_join(bad, "\n", fn {mod, name, arity} ->
                 "  #{inspect(mod)} emits #{name}/#{arity} — not in HelpersCodegen.helper_names/0"
               end)
    end

    test "the walk is non-trivial (sanity: producers actually emit py_* refs)" do
      # Guard against the static walk silently finding zero references
      # (e.g. if Macro.prewalk's traversal regresses). Builtins alone
      # emits py_int, py_str, py_len, py_abs, py_add, etc.
      builtins_refs =
        Pylixir.Builtins
        |> source_path()
        |> File.read!()
        |> Code.string_to_quoted!()
        |> collect_py_refs()

      assert length(builtins_refs) > 5,
             "expected the static walk to find several py_* references in Builtins; found #{length(builtins_refs)}"
    end
  end
end
