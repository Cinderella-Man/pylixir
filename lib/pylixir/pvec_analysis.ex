defmodule Pylixir.PvecAnalysis do
  @moduledoc """
  Compile-time analysis that recognises the "pre-allocate then index-write"
  pattern and lets the converter back the storage with Erlang's `:array`
  (a persistent-vector) instead of a plain Elixir list.

  ## The pattern

      xs = [<literal_default>] * <expr>
      for j in range(...):
          xs[j] = <expr>          # subscript-write
      ...                          # indexed reads of xs

  Lowered into a plain list, `xs[j] = v` becomes `List.replace_at/3`
  which is O(n) per write, so an N-element fill loop costs O(N²). At
  N=10⁵ that's ~10⁹ writes — solidly into timeout territory. Backing
  `xs` with an `:array` gives O(log n) per write/read and drops the
  build cost to ~N log N.

  ## What the converter does with a positive result

    1. The bind `xs = [<default>] * <n>` is rewritten to
       `xs = py_pvec_new(<n>, <default>)`, allocating an `:array`
       sized to `n` with the default value.
    2. `xs[i] = v` lowers through the standard `py_setitem` helper,
       which now has a leading `{:py_pvec, _}` clause that delegates
       to `py_pvec_set` (`:array.set`).
    3. `xs[i]` reads go through `py_getitem` ↦ `py_pvec_get`
       (`:array.get`).
    4. The type tracker records `xs` as `{:py_pvec, e}` so `coerce_iter`
       wraps it in `py_iter_to_list` before iteration consumers, and
       `len/in/repr/str/copy/index/count` all reach the matching
       `{:py_pvec, _}` helper clauses.

  ## Public API

  `analyze/1,2` returns `%{name => default_ast}` — the AST of the
  default value for each freezable pre-alloc name. The converter
  consults this map when emitting an Assign to decide whether to
  rewrite the RHS into `py_pvec_new(<n>, default)`.

  ## Disqualifiers

    * Bind is not `xs = [<literal>] * <expr>` (e.g. literal length
      multiplier, multiple-element list literal, non-literal default,
      etc.). The `[default] * n` shape with a single element is the
      only candidate.
    * `xs` is reassigned anywhere else (`xs = ...`, `for xs in ...`,
      tuple-unpack including `xs`).
    * Any non-subscript mutation: `.append()` (would grow it),
      `.sort()`, `.pop()`, `+=`, `del xs`, …
    * Any leak: `y = xs`, `return xs`, `f(xs)` for non-allowlisted
      `f`, `xs + ys`, etc. (Same allowlist as `Pylixir.AlistAnalysis`.)
    * `xs` is mentioned inside a nested `def`/`lambda`/`class`/
      comprehension — conservatively bails because the closure could
      mutate it.

  ## Debug knobs

    * `PYLIXIR_DISABLE_PVEC=1` — return an empty map. Same escape-hatch
      style as the alist analysis.
    * `PYLIXIR_PVEC_DIAG=1` — emit one line per decision to stderr,
      `[pvec] f=<scope> x=<name> decision=…`.
  """

  @read_only_builtins ~w(
    len sum min max any all sorted reversed enumerate zip
    iter list str repr print map filter abs bool
  )

  @read_only_methods ~w(index count copy)

  @spec analyze([map()], String.t()) :: %{optional(String.t()) => map()}
  def analyze(body, scope_name \\ "(module)") when is_list(body) do
    if disabled?() do
      %{}
    else
      body
      |> collect_pre_alloc_binds()
      |> Enum.group_by(fn {n, _, _} -> n end)
      |> Enum.flat_map(fn {name, binds} ->
        # All entries here are `[d] * n` shaped (that's all
        # `collect_pre_alloc_binds` collects). Multiple binds for the
        # same name — typically in mutually-exclusive branches
        # (`if …: arr = [0]*n  else: arr = [0]*n`) — are fine: every
        # bind re-inits to a pvec, so the name is always a pvec. We
        # skip ALL of them in the reassignment check; a non-pvec
        # reassignment elsewhere still bails. The emission re-derives
        # each bind's own default from its RHS, so differing defaults
        # are handled correctly.
        binding_nodes = Enum.map(binds, fn {_, _, node} -> node end)
        {_, default_ast, _} = hd(binds)

        if decide(name, body, binding_nodes) do
          log_decision(scope_name, name, :froze, nil)
          [{name, default_ast}]
        else
          log_decision(scope_name, name, :bailed, "reassigned_or_leaked")
          []
        end
      end)
      |> Map.new()
    end
  end

  # --- candidate discovery -------------------------------------------

  # `xs = [<literal>] * <n>` — single-element list literal multiplied
  # by some integer expression. The literal is the per-slot default,
  # `<n>` is computed at runtime to size the array. Both `[d] * n` and
  # `n * [d]` shapes are accepted (Python's `*` is commutative for
  # list × int).
  # Descend into same-scope control flow (`For`/`While`/`If`/`Try`)
  # so a `[d] * n` bind nested in a loop or branch is still found
  # (eval-corpus seed_17116: `original = [0]*n` rebuilt per
  # candidate inside a `for`). Does NOT cross into nested
  # `FunctionDef`/`Lambda`/`ClassDef` bodies — those are separate
  # scopes analysed on their own.
  defp collect_pre_alloc_binds(body) do
    Enum.flat_map(body, &collect_binds_node/1)
  end

  defp collect_binds_node(
         %{
           "_type" => "Assign",
           "targets" => [%{"_type" => "Name", "id" => name}],
           "value" => %{
             "_type" => "BinOp",
             "op" => %{"_type" => "Mult"},
             "left" => left,
             "right" => right
           }
         } = node
       ) do
    case pre_alloc_default(left, right) do
      {:ok, default_ast} -> [{name, default_ast, node}]
      :no -> []
    end
  end

  defp collect_binds_node(%{"_type" => type} = node)
       when type in ["For", "AsyncFor", "While", "If", "Try", "With", "AsyncWith"] do
    nested =
      [Map.get(node, "body"), Map.get(node, "orelse"), Map.get(node, "finalbody")]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&collect_pre_alloc_binds/1)

    handler_binds =
      node
      |> Map.get("handlers", [])
      |> Enum.flat_map(fn h -> collect_pre_alloc_binds(Map.get(h, "body", [])) end)

    nested ++ handler_binds
  end

  defp collect_binds_node(_), do: []

  # Either side may be the single-element list literal. Returns the
  # default-value AST when exactly one side matches.
  defp pre_alloc_default(%{"_type" => "List", "elts" => [d]}, _other), do: {:ok, d}
  defp pre_alloc_default(_other, %{"_type" => "List", "elts" => [d]}), do: {:ok, d}
  defp pre_alloc_default(_, _), do: :no

  # --- per-candidate decision ----------------------------------------

  defp decide(name, body, binding_nodes) do
    not reassigned?(body, name, binding_nodes) and
      not leaked?(body, name) and
      not mentioned_in_nested_scope?(body, name)
  end

  # Reassignment = any Assign/AugAssign/For-target that mentions `name`,
  # *other than* one of the pre-alloc bindings themselves.
  # Subscript-assigns on `xs[i]` are not reassignments — those are the
  # writes we want.
  defp reassigned?(body, name, binding_nodes) do
    Enum.any?(body, &reassigns_deep?(&1, name, binding_nodes))
  end

  defp reassigns_deep?(%{"_type" => _} = node, name, binding_nodes) do
    cond do
      Enum.member?(binding_nodes, node) ->
        false

      reassigns_here?(node, name) ->
        true

      true ->
        node
        |> Map.delete("_type")
        |> Enum.any?(fn {_k, v} -> reassigns_deep?(v, name, binding_nodes) end)
    end
  end

  defp reassigns_deep?(list, name, binding_nodes) when is_list(list),
    do: Enum.any?(list, &reassigns_deep?(&1, name, binding_nodes))

  defp reassigns_deep?(_, _, _), do: false

  defp reassigns_here?(%{"_type" => "Assign", "targets" => targets}, name) do
    Enum.any?(targets, &name_target?(&1, name))
  end

  defp reassigns_here?(%{"_type" => "AugAssign", "target" => t}, name),
    do: name_target?(t, name)

  defp reassigns_here?(%{"_type" => "For", "target" => t}, name), do: name_target?(t, name)

  defp reassigns_here?(%{"_type" => "Delete", "targets" => targets}, name) do
    Enum.any?(targets, fn t ->
      case t do
        %{"_type" => "Name", "id" => ^name} -> true
        _ -> false
      end
    end)
  end

  defp reassigns_here?(_, _), do: false

  defp name_target?(%{"_type" => "Name", "id" => id}, name), do: id == name

  defp name_target?(%{"_type" => "Tuple", "elts" => elts}, name),
    do: Enum.any?(elts, &name_target?(&1, name))

  defp name_target?(%{"_type" => "List", "elts" => elts}, name),
    do: Enum.any?(elts, &name_target?(&1, name))

  defp name_target?(%{"_type" => "Starred", "value" => v}, name), do: name_target?(v, name)
  defp name_target?(_, _), do: false

  # --- leak / non-allowlisted-mutation check -------------------------

  defp leaked?(body, name) do
    Enum.any?(body, &leak_in?(&1, name))
  end

  # The candidate's own `xs = [<default>] * <n>` Assign — the target
  # `Name(xs)` is the bind site, not a leak. Walk only the value
  # so any `xs` reference inside the RHS still gets caught via
  # descent (e.g. `xs = [xs] * 5` would flag the right way). A
  # reassignment would have been rejected upstream by the
  # "multiple binds" check.
  defp leak_in?(
         %{
           "_type" => "Assign",
           "targets" => [%{"_type" => "Name", "id" => target_id}],
           "value" =>
             %{
               "_type" => "BinOp",
               "op" => %{"_type" => "Mult"}
             } = value
         },
         name
       )
       when target_id == name do
    leak_in?(value, name)
  end

  # `xs[<slice>] = ...` — slice-assign disqualifies. Grows or shrinks
  # the storage; `py_slice_assign` doesn't know about pvec. Flag as
  # a leak directly so the candidate bails.
  defp leak_in?(
         %{
           "_type" => "Assign",
           "targets" => [
             %{
               "_type" => "Subscript",
               "value" => %{"_type" => "Name", "id" => target_id},
               "slice" => %{"_type" => "Slice"}
             }
           ]
         },
         name
       )
       when target_id == name do
    true
  end

  # `xs[i] = v` subscript-assign — allowed. Walk the slice expression
  # for embedded `xs` references but don't flag the bare `Name(xs)`
  # in the target's value slot.
  defp leak_in?(
         %{
           "_type" => "Assign",
           "targets" => [
             %{
               "_type" => "Subscript",
               "value" => %{"_type" => "Name", "id" => target_id},
               "slice" => slice
             }
           ],
           "value" => value
         },
         name
       )
       when target_id == name do
    leak_in?(slice, name) or leak_in?(value, name)
  end

  # `xs.<method>(...)` — only the read-only allowlist receivers are
  # safe. Mutating-but-allowed methods are NONE for pvec (.append
  # would change the size; we don't grow pvecs).
  defp leak_in?(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => recv},
             "attr" => attr
           },
           "args" => args
         } = call,
         name
       )
       when recv == name do
    kws = Map.get(call, "keywords", [])

    cond do
      attr in @read_only_methods ->
        Enum.any?(args, &leak_in?(&1, name)) or Enum.any?(kws, &leak_in?(&1, name))

      true ->
        true
    end
  end

  # `xs[i]` / `xs[a:b]` — read shape. Receiver slot safe; slice walked.
  defp leak_in?(%{"_type" => "Subscript", "value" => value, "slice" => slice}, name) do
    leak_in_value_slot?(value, name) or leak_in?(slice, name)
  end

  # `v in xs` / `v not in xs` — read shape.
  defp leak_in?(
         %{"_type" => "Compare", "left" => left, "ops" => ops, "comparators" => comps},
         name
       ) do
    left_leak = leak_in?(left, name)

    pair_leak =
      ops
      |> Enum.zip(comps)
      |> Enum.any?(fn {op, comp} ->
        case {op, comp} do
          {%{"_type" => kind}, %{"_type" => "Name", "id" => ^name}}
          when kind in ["In", "NotIn"] ->
            false

          _ ->
            leak_in?(comp, name)
        end
      end)

    left_leak or pair_leak
  end

  # `for v in xs:` — iter slot safe; everything else walked.
  defp leak_in?(
         %{"_type" => "For", "target" => target, "iter" => iter, "body" => body} = node,
         name
       ) do
    orelse = Map.get(node, "orelse", [])

    leak_in_value_slot?(iter, name) or
      leak_in?(target, name) or
      Enum.any?(body, &leak_in?(&1, name)) or
      Enum.any?(orelse, &leak_in?(&1, name))
  end

  # Read-only builtin call: `len(xs)`, `sum(xs)`, etc. Receiver-arg
  # slot safe; other args walked.
  defp leak_in?(
         %{
           "_type" => "Call",
           "func" => %{"_type" => "Name", "id" => fname},
           "args" => args
         } = call,
         name
       )
       when fname in @read_only_builtins do
    kws = Map.get(call, "keywords", [])

    args_leak =
      Enum.any?(args, fn arg ->
        case arg do
          %{"_type" => "Name", "id" => ^name} -> false
          other -> leak_in?(other, name)
        end
      end)

    args_leak or Enum.any?(kws, &leak_in?(&1, name))
  end

  # `return xs` — admitted as safe. The caller receives the
  # `{:py_pvec, _}` value as-is; py_getitem/py_setitem and all
  # iter-consumers handle the tag transparently. Without this clause
  # a helper function that builds and returns a pvec would fall back
  # to a plain list lowering (eval-corpus `seed_14984` shape:
  # `def compute_counts(n): xs = [0] * n; …; return xs` — `s=10⁶`
  # wedged at O(n²) `List.replace_at` per write).
  defp leak_in?(%{"_type" => "Return", "value" => %{"_type" => "Name", "id" => id}}, name)
       when id == name,
       do: false

  # Bare `Name(xs)` not absorbed by a safe-slot clause = leak.
  defp leak_in?(%{"_type" => "Name", "id" => id}, name) when id == name, do: true

  # Generic descent.
  defp leak_in?(%{"_type" => _} = node, name) do
    node
    |> Map.delete("_type")
    |> Enum.any?(fn {_k, v} -> leak_in?(v, name) end)
  end

  defp leak_in?(list, name) when is_list(list), do: Enum.any?(list, &leak_in?(&1, name))

  defp leak_in?(_, _), do: false

  defp leak_in_value_slot?(%{"_type" => "Name", "id" => id}, name) when id == name, do: false
  defp leak_in_value_slot?(other, name), do: leak_in?(other, name)

  # --- nested-scope check --------------------------------------------

  # If `xs` is mentioned anywhere inside a nested `def`/`lambda`/
  # `class`/comprehension, conservatively bail (the closure could
  # mutate it through a path we can't see from outside).
  defp mentioned_in_nested_scope?(body, name) do
    Enum.any?(body, &nested_mentions?(&1, name))
  end

  defp nested_mentions?(%{"_type" => type} = node, name)
       when type in [
              "FunctionDef",
              "AsyncFunctionDef",
              "Lambda",
              "ClassDef",
              "ListComp",
              "SetComp",
              "DictComp",
              "GeneratorExp"
            ] do
    name_anywhere?(node, name)
  end

  defp nested_mentions?(%{"_type" => _} = node, name) do
    node
    |> Map.delete("_type")
    |> Enum.any?(fn {_k, v} -> nested_mentions?(v, name) end)
  end

  defp nested_mentions?(list, name) when is_list(list),
    do: Enum.any?(list, &nested_mentions?(&1, name))

  defp nested_mentions?(_, _), do: false

  defp name_anywhere?(%{"_type" => "Name", "id" => id}, name) when id == name, do: true

  defp name_anywhere?(%{"_type" => _} = node, name) do
    node
    |> Map.delete("_type")
    |> Enum.any?(fn {_k, v} -> name_anywhere?(v, name) end)
  end

  defp name_anywhere?(list, name) when is_list(list),
    do: Enum.any?(list, &name_anywhere?(&1, name))

  defp name_anywhere?(_, _), do: false

  # --- debug knobs ----------------------------------------------------

  defp disabled? do
    case System.get_env("PYLIXIR_DISABLE_PVEC") do
      v when v in [nil, "", "0"] -> false
      _ -> true
    end
  end

  defp diag_enabled? do
    case System.get_env("PYLIXIR_PVEC_DIAG") do
      v when v in [nil, "", "0"] -> false
      _ -> true
    end
  end

  defp log_decision(scope, name, :froze, _reason) do
    if diag_enabled?() do
      IO.puts(:stderr, "[pvec] f=#{scope} x=#{name} decision=froze")
    end

    :ok
  end

  defp log_decision(scope, name, :bailed, reason) do
    if diag_enabled?() do
      IO.puts(:stderr, "[pvec] f=#{scope} x=#{name} decision=bailed reason=#{reason}")
    end

    :ok
  end
end
