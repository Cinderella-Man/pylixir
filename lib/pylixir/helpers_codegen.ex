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

  ## Tree-shaking (`helpers_ast_for/1`)

  Splicing every helper into every generated module bloated the output by
  several KB of `def`s that the user's code never called. `helpers_ast_for/1`
  takes the *emitted user code AST* (everything that will be spliced after
  the helpers in `TranslatedCode`), walks it for helper-name references,
  computes the transitive closure against a compile-time dependency map,
  and returns just the clauses needed.

  Returned clauses stay as `def` (not `defp`): tree-shaking strips unused
  *whole helpers*, but a kept helper like `truthy?` still has 9 clauses
  the user code never matches against, and the Elixir compiler emits
  per-clause "this clause is never used" warnings for `defp` based on
  call-site pattern coverage. `def` suppresses those — the same reason
  implementation.md §"Reason helpers are `def` not `defp`" gave for
  pre-tree-shaking emission.
  """

  # The core helpers file plus per-topic submodule files. Each topic
  # is a `defmodule Pylixir.RuntimeHelpers.<Topic> do … end` that's
  # also testable in isolation; the sentinel-delimited block is what
  # gets spliced into generated `TranslatedCode` modules.
  @helper_files [
    Path.join([__DIR__, "runtime_helpers.ex"]),
    Path.join([__DIR__, "runtime_helpers", "format.ex"]),
    Path.join([__DIR__, "runtime_helpers", "regex.ex"]),
    Path.join([__DIR__, "runtime_helpers", "math_ext.ex"])
  ]

  for path <- @helper_files, do: @external_resource(path)

  @start_sentinel "# --- HELPERS START ---"
  @end_sentinel "# --- HELPERS END ---"

  @helpers_source @helper_files
                  |> Enum.map(fn path ->
                    raw = File.read!(path)
                    [_before, rest] = String.split(raw, @start_sentinel, parts: 2)
                    [body, _after] = String.split(rest, @end_sentinel, parts: 2)
                    String.trim(body)
                  end)
                  |> Enum.join("\n\n")

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

  # Compile-time index: every `def` head unwrapped to `{name, args}`.
  # Used to feed the by-name / order / deps tables below. Mirrors the
  # `head` extraction shape that `@helper_names` already relied on.
  @helper_heads Enum.map(@helpers_ast, fn {:def, _, [head, _body_kw]} ->
                  case head do
                    {:when, _, [{n, _, a}, _guard]} -> {n, a || []}
                    {n, _, a} -> {n, a || []}
                  end
                end)

  # `name -> [def_ast]`. Multi-clause helpers (e.g. `py_add` has 8
  # clauses) must be spliced together; this map keeps them grouped.
  @helpers_by_name @helpers_ast
                   |> Enum.zip(@helper_heads)
                   |> Enum.reduce(%{}, fn {def_ast, {name, _args}}, acc ->
                     Map.update(acc, name, [def_ast], &[def_ast | &1])
                   end)
                   |> Enum.into(%{}, fn {k, v} -> {k, Enum.reverse(v)} end)

  # First-seen order of helper names across the parsed source. Preserves
  # the canonical emission order so output diffs after tree-shaking only
  # show *removals*, not reorderings.
  @helper_order @helper_heads
                |> Enum.reduce({[], MapSet.new()}, fn {name, _}, {order, seen} ->
                  if MapSet.member?(seen, name) do
                    {order, seen}
                  else
                    {[name | order], MapSet.put(seen, name)}
                  end
                end)
                |> elem(0)
                |> Enum.reverse()

  @helper_name_set MapSet.new(@helper_order)

  # `name -> [other_helper_name]`. For each clause body, prewalk for
  # `{atom, _, _}` nodes whose atom is a known helper name. Catches
  # both direct calls (`py_str(x)` → args is a list) AND capture-form
  # references (`&py_str/1` → the inner `{:py_str, [], nil}` has nil
  # as the args slot). Membership in `@helper_name_set` is the filter
  # — bare local vars never share a helper name (helpers are `py_*`
  # or end in `?`, neither of which appears in helper-body locals).
  # Self-references are stripped so the closure walk doesn't churn.
  # Stored as plain lists (not MapSets) to avoid Dialyzer's opaque-
  # widening complaints on module attributes.
  @helper_deps (
                 helper_set = @helper_name_set

                 for {name, clauses} <- @helpers_by_name, into: %{} do
                   deps =
                     clauses
                     |> Enum.flat_map(fn {:def, _, [_head, kw]} ->
                       body = Keyword.get(kw, :do)

                       {_, found} =
                         Macro.prewalk(body, [], fn
                           {n, _, _} = node, acc when is_atom(n) ->
                             if MapSet.member?(helper_set, n),
                               do: {node, [n | acc]},
                               else: {node, acc}

                           other, acc ->
                             {other, acc}
                         end)

                       found
                     end)
                     |> Enum.uniq()
                     |> Enum.reject(&(&1 == name))

                   {name, deps}
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

  Used by tests; the Converter calls `helpers_ast_for/1` instead so the
  output only carries helpers the user code actually reaches.
  """
  @spec helpers_ast() :: [Macro.t()]
  def helpers_ast, do: @helpers_ast

  @doc """
  Tree-shaken helper splice: walks `emitted_asts` for helper-name
  references, expands transitively against the compile-time dep map,
  and returns the matching clauses as `defp` ASTs in canonical order.

  `emitted_asts` should be the list of AST nodes that will be spliced
  into `TranslatedCode` *after* the helpers — module attrs, class
  bodies, top-level defps, while-helpers, and the `py_main` def.
  Returns `[]` when nothing references a helper.
  """
  @float_chain MapSet.new([
                 :py_str_float,
                 :python_sci,
                 :shift_decimal,
                 :drop_trailing_zero_decimal
               ])

  # Helpers that internally call `py_str(v)` with an arg that could
  # be a container at runtime. If any of these are in the pulled set,
  # py_str's container clauses must stay (P3 soundness).
  @polymorphic_py_str_callers MapSet.new([
                                :format_percent_typed,
                                :py_format_value,
                                :py_str_format_map
                              ])

  @spec helpers_ast_for([Macro.t()], keyword()) :: [Macro.t()]
  def helpers_ast_for(emitted_asts, opts \\ []) when is_list(emitted_asts) do
    roots = collect_helper_refs(emitted_asts)
    needed = transitive_closure(roots)

    drop_float = Keyword.get(opts, :drop_float, false)

    # M6 — when no float reaches `py_str`, drop the entire
    # `py_str_float` chain and post-process py_str to remove its
    # is_float clause. Soundness: caller passes `drop_float: true`
    # only after `ModuleAnalysis.uses_float` returned false.
    needed = if drop_float, do: MapSet.difference(needed, @float_chain), else: needed

    # P3 — drop py_str's container clauses (is_list/is_tuple/%MapSet/
    # is_map) when no path reaches py_str with a container arg. Two
    # sufficient conditions, both must hold:
    #   1. User code emits no direct `{:py_str, _, _}` ref (so all
    #      user-typed call sites routed containers through py_repr
    #      per P1).
    #   2. No pulled helper internally calls `py_str(maybe_container)`
    #      — gated on @polymorphic_py_str_callers ∩ needed = ∅.
    # py_repr's own catch-all to py_str is safe: it only fires for
    # non-containers (py_repr's container clauses match first).
    drop_containers =
      not MapSet.member?(roots, :py_str) and
        MapSet.disjoint?(@polymorphic_py_str_callers, needed)

    # Phase 6 — static container-usage shake of py_repr's per-type
    # clauses. Caller sets each opt based on
    # `ModuleAnalysis.uses_tuple/set/dict`. Soundness: walker is
    # over-approximate (e.g. multi-assign `a, b =` is excluded), so
    # a `false` flag means no value of that container type can flow
    # through py_repr at runtime.
    flags = %{
      drop_float: drop_float,
      drop_containers: drop_containers,
      drop_tuple: Keyword.get(opts, :drop_tuple_clause, false),
      drop_set: Keyword.get(opts, :drop_set_clause, false),
      drop_dict: Keyword.get(opts, :drop_dict_clause, false)
    }

    for name <- @helper_order,
        MapSet.member?(needed, name),
        def_ast <- Map.fetch!(@helpers_by_name, name),
        keep_clause?(name, def_ast, flags),
        do: def_ast
  end

  defp keep_clause?(:py_str, def_ast, %{drop_float: df, drop_containers: dc}) do
    not (df and is_float_guarded?(def_ast)) and
      not (dc and is_container_clause?(def_ast))
  end

  defp keep_clause?(:py_repr, def_ast, %{drop_tuple: dt, drop_set: ds, drop_dict: dd}) do
    not (dt and is_tuple_clause?(def_ast)) and
      not (ds and is_set_clause?(def_ast)) and
      not (dd and is_dict_clause?(def_ast))
  end

  defp keep_clause?(_name, _def_ast, _flags), do: true

  defp is_float_guarded?({:def, _, [{:when, _, [_head, guard]}, _body]}),
    do: contains_is_float?(guard)

  defp is_float_guarded?(_), do: false

  defp contains_is_float?({:is_float, _, _args}), do: true

  defp contains_is_float?({_op, _meta, args}) when is_list(args),
    do: Enum.any?(args, &contains_is_float?/1)

  defp contains_is_float?(_), do: false

  # py_str container clauses: heads guarded by is_list / is_tuple /
  # is_map, plus the `%MapSet{} = s` struct-match clause.
  defp is_container_clause?({:def, _, [{:when, _, [_head, guard]}, _body]}),
    do: contains_container_guard?(guard)

  defp is_container_clause?({:def, _, [head, _body]}),
    do: matches_mapset_struct?(head)

  defp is_container_clause?(_), do: false

  defp contains_container_guard?({op, _, _})
       when op in [:is_list, :is_tuple, :is_map],
       do: true

  defp contains_container_guard?({_op, _meta, args}) when is_list(args),
    do: Enum.any?(args, &contains_container_guard?/1)

  defp contains_container_guard?(_), do: false

  defp matches_mapset_struct?({_name, _, args}) when is_list(args) do
    Enum.any?(args, fn
      {:=, _, [{:%, _, [{:__aliases__, _, [:MapSet]}, _]}, _]} -> true
      _ -> false
    end)
  end

  defp matches_mapset_struct?(_), do: false

  # Phase 6 per-type predicates for py_repr clause shaking.
  defp is_tuple_clause?({:def, _, [{:when, _, [_head, guard]}, _body]}),
    do: contains_guard?(guard, :is_tuple)

  defp is_tuple_clause?(_), do: false

  defp is_set_clause?({:def, _, [head, _body]}), do: matches_mapset_struct?(head)
  defp is_set_clause?(_), do: false

  # `def py_repr(x) when is_map(x) and not is_struct(x)` — the dict
  # clause. is_map alone would also match the MapSet struct clause
  # via `is_struct(x, MapSet)` which is `is_map(x) and ...`, but
  # MapSet's clause head uses `%MapSet{} = s` not a when-guard, so
  # the `is_map`-guarded clause is unambiguously the dict one.
  defp is_dict_clause?({:def, _, [{:when, _, [_head, guard]}, _body]}),
    do: contains_guard?(guard, :is_map)

  defp is_dict_clause?(_), do: false

  defp contains_guard?({op, _, _}, op), do: true

  defp contains_guard?({_op, _meta, args}, target) when is_list(args),
    do: Enum.any?(args, &contains_guard?(&1, target))

  defp contains_guard?(_, _), do: false

  defp collect_helper_refs(asts) do
    Enum.reduce(asts, MapSet.new(), fn ast, acc ->
      {_, found} =
        Macro.prewalk(ast, acc, fn
          {n, _, _} = node, a when is_atom(n) ->
            if MapSet.member?(@helper_name_set, n),
              do: {node, MapSet.put(a, n)},
              else: {node, a}

          other, a ->
            {other, a}
        end)

      found
    end)
  end

  defp transitive_closure(roots) do
    expand(roots, roots)
  end

  defp expand(current, frontier) do
    new_frontier =
      frontier
      |> Enum.flat_map(fn name -> Map.get(@helper_deps, name, []) end)
      |> Enum.reject(&MapSet.member?(current, &1))
      |> MapSet.new()

    if MapSet.size(new_frontier) == 0 do
      current
    else
      expand(MapSet.union(current, new_frontier), new_frontier)
    end
  end

  # Compute the set of `{name, arity}` pairs at Pylixir's compile time so
  # the linkage check (see `test/pylixir/helpers_linkage_test.exs`) costs
  # nothing at runtime. Helpers with a `when` guard wrap the head in
  # `{:when, _, [{name, _, args}, guard]}` — unwrap before extracting.
  @helper_names @helper_heads
                |> Enum.map(fn {name, args} ->
                  arity = if is_list(args), do: length(args), else: 0
                  {name, arity}
                end)
                |> MapSet.new()

  @doc """
  Set of `{name, arity}` pairs for every helper spliced into the
  generated module. Used by the helpers-linkage test to verify that
  every `py_*` reference emitted by `Pylixir.Builtins` / `Pylixir.Stdlib.*`
  resolves to a real helper — a typo or rename surfaces at Pylixir's
  test time rather than in user code at runtime.
  """
  # `MapSet` is opaque; the compile-time fold materialises its internal
  # `%MapSet{:map => %{tuple => []}}` shape and Dialyzer's success
  # typing then refuses to widen back to the opaque `MapSet.t()`. The
  # value *is* a MapSet at runtime — this is a known false positive.
  @dialyzer {:nowarn_function, helper_names: 0}
  @spec helper_names() :: MapSet.t()
  def helper_names, do: @helper_names
end
