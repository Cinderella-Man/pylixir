defmodule Pylixir.LiteralPropagation do
  @moduledoc """
  Static folding of Python `repr` / `str` / `format` / `print` /
  f-string / `%`-format / `.format()` call sites whose inputs are
  provably literal — at the Python-AST level, before the converter
  runs.

  Architecture (plan doc: `docs/05_static-repr-folding.md`):

    * **(iv-a) Local fold.** Every emit-site that takes a value and
      produces a string gets a per-shape rewriter (`Call(repr, lit)`,
      `Call(str, lit)`, `print(lit, …)`, etc.) that tries to fold its
      arg to a `Constant(value=<computed_binary>)`. Algorithm reuse:
      `LiteralFold.repr_of/1` / `str_of/1` for repr/str; the existing
      runtime helpers `py_str_percent_format` / `py_format_value` are
      called directly at compile time for the heavier `%`-format and
      `.format()` paths.

    * **Phase 1 — direct binding.** Resolve `Name(N)` to its bound
      value when N is assigned exactly once to a foldable expression
      and no mutation / alias / escape site is observed for N in the
      module.

    * **Phase 2 — constant-returning function.** Resolve
      `Call(Name(F), args)` to F's return literal when F's body is
      `[<docstring?>, Return(foldable)]` AND every call arg is itself
      side-effect-free (recursively).

    * **Phase 3 — closure-capture.** All Phase 1 / 2 gate walks
      recurse into Lambda / FunctionDef bodies. Any mutation / alias /
      escape inside any inner closure invalidates the fold of the
      captured name. Strict: refuse fold rather than reason about
      time-ordering.

  Fixpoint: rewrites can enable new rewrites (e.g. folding `f()` to a
  literal then folding `print(f())` afterwards). Iterate until stable,
  capped at `@max_iters`.
  """

  alias Pylixir.{LiteralFold, RuntimeHelpers}
  alias Pylixir.RuntimeHelpers.Format, as: RuntimeFormat

  @max_iters 4

  # Python list/dict/set method names that mutate the receiver. Used by
  # `collect_mutations/1` to disqualify literal-binding folds.
  @mutating_methods MapSet.new(~w(
    append extend insert pop popitem clear sort reverse remove
    update setdefault add discard
    intersection_update difference_update symmetric_difference_update
  ))

  @spec rewrite([map()]) :: [map()]
  def rewrite(body) when is_list(body) do
    Enum.reduce_while(1..@max_iters, body, fn _i, b ->
      case one_pass(b) do
        ^b -> {:halt, b}
        next -> {:cont, next}
      end
    end)
  end

  defp one_pass(body) do
    info = scan(body)
    rewrite_body(body, info)
  end

  # ----- Flow-table scan ------------------------------------------------

  defp scan(body) do
    %{
      literal_bindings: collect_literal_bindings(body),
      mutation_sites: collect_mutations(body),
      alias_sites: collect_aliases(body),
      escape_sites: collect_escapes(body),
      constant_functions: collect_constant_fns(body)
    }
  end

  @doc false
  # Phase 1+3: names assigned exactly once to a foldable expression.
  # Recurses into closure bodies — a name shadowed inside a closure
  # has its own binding, but a free Name(N) reference inside a closure
  # still counts toward "uses of N from the enclosing scope". We
  # collect both module-level and inner-scope bindings into one flat
  # map: callers consult it by name only. Conservative: when the same
  # name is bound in multiple scopes (top-level + nested), the multi-
  # binding cancels out and the name doesn't make it into the
  # `literal_bindings` table.
  def collect_literal_bindings(body) do
    assigns = collect_all_assigns(body)
    counts = Enum.reduce(assigns, %{}, fn {n, _}, acc -> Map.update(acc, n, 1, &(&1 + 1)) end)

    for {name, value_node} <- assigns,
        Map.get(counts, name) == 1,
        {:ok, value} <- [LiteralFold.fold(value_node)],
        into: %{} do
      {name, value}
    end
  end

  defp collect_all_assigns(node), do: do_collect_assigns(node, [])

  defp do_collect_assigns(
         %{"_type" => "Assign", "targets" => targets, "value" => value} = node,
         acc
       ) do
    acc =
      targets
      |> Enum.flat_map(&assign_target_names/1)
      |> Enum.reduce(acc, fn n, a -> [{n, value} | a] end)

    # Recurse into the value (Lambdas / closures contained in it).
    do_collect_assigns_children(node, acc)
  end

  defp do_collect_assigns(node, acc) when is_map(node) do
    do_collect_assigns_children(node, acc)
  end

  defp do_collect_assigns(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &do_collect_assigns/2)
  end

  defp do_collect_assigns(_leaf, acc), do: acc

  defp do_collect_assigns_children(node, acc) when is_map(node) do
    node
    |> Map.delete("_type")
    |> Enum.reduce(acc, fn {_k, v}, a -> do_collect_assigns(v, a) end)
  end

  defp assign_target_names(%{"_type" => "Name", "id" => id}), do: [id]
  defp assign_target_names(_), do: []

  @doc false
  # Phase 1+3: names appearing in mutation positions anywhere in the
  # module (including closure bodies).
  def collect_mutations(body), do: do_collect_mutations(body, MapSet.new())

  defp do_collect_mutations(%{"_type" => "AugAssign", "target" => target} = node, acc) do
    acc = mark_target(acc, target)
    do_collect_mutations_children(node, acc)
  end

  defp do_collect_mutations(
         %{"_type" => "Assign", "targets" => targets, "value" => _} = node,
         acc
       ) do
    # Subscript / Attribute targets mutate the container they're
    # subscripted into. A plain Name target is a rebind — caught
    # separately by the def-count gate; don't mark it as mutation.
    acc =
      Enum.reduce(targets, acc, fn t, a ->
        case t do
          %{"_type" => "Subscript"} -> mark_target(a, t)
          %{"_type" => "Attribute"} -> mark_target(a, t)
          _ -> a
        end
      end)

    do_collect_mutations_children(node, acc)
  end

  defp do_collect_mutations(%{"_type" => "Delete", "targets" => targets} = node, acc) do
    acc = Enum.reduce(targets, acc, &mark_target(&2, &1))
    do_collect_mutations_children(node, acc)
  end

  defp do_collect_mutations(
         %{
           "_type" => "Expr",
           "value" => %{
             "_type" => "Call",
             "func" => %{
               "_type" => "Attribute",
               "value" => %{"_type" => "Name", "id" => receiver},
               "attr" => attr
             }
           }
         } = node,
         acc
       ) do
    acc =
      if MapSet.member?(@mutating_methods, attr), do: MapSet.put(acc, receiver), else: acc

    do_collect_mutations_children(node, acc)
  end

  defp do_collect_mutations(node, acc) when is_map(node) do
    do_collect_mutations_children(node, acc)
  end

  defp do_collect_mutations(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &do_collect_mutations/2)
  end

  defp do_collect_mutations(_leaf, acc), do: acc

  defp do_collect_mutations_children(node, acc) when is_map(node) do
    node
    |> Map.delete("_type")
    |> Enum.reduce(acc, fn {_k, v}, a -> do_collect_mutations(v, a) end)
  end

  # Subscript/Attribute target → mark the root name as mutated.
  defp mark_target(acc, %{"_type" => "Name", "id" => id}), do: MapSet.put(acc, id)

  defp mark_target(acc, %{"_type" => "Subscript", "value" => inner}),
    do: mark_target(acc, inner)

  defp mark_target(acc, %{"_type" => "Attribute", "value" => inner}),
    do: mark_target(acc, inner)

  defp mark_target(acc, %{"_type" => "Tuple", "elts" => elts}),
    do: Enum.reduce(elts, acc, &mark_target(&2, &1))

  defp mark_target(acc, %{"_type" => "List", "elts" => elts}),
    do: Enum.reduce(elts, acc, &mark_target(&2, &1))

  defp mark_target(acc, _), do: acc

  @doc false
  # Phase 1+3: names that appear as the RHS of any non-trivial Assign
  # — i.e. a binding `M = expr` where `expr` syntactically contains
  # Name(N) in a Load position. Conservative: any such occurrence
  # disqualifies N from the literal table, because M might be a
  # mutating alias for N.
  def collect_aliases(body), do: do_collect_aliases(body, MapSet.new())

  defp do_collect_aliases(
         %{"_type" => "Assign", "targets" => _, "value" => value} = node,
         acc
       ) do
    acc = collect_names_in(value, acc)
    do_collect_aliases_children(node, acc)
  end

  defp do_collect_aliases(node, acc) when is_map(node) do
    do_collect_aliases_children(node, acc)
  end

  defp do_collect_aliases(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &do_collect_aliases/2)

  defp do_collect_aliases(_leaf, acc), do: acc

  defp do_collect_aliases_children(node, acc) when is_map(node) do
    node
    |> Map.delete("_type")
    |> Enum.reduce(acc, fn {_k, v}, a -> do_collect_aliases(v, a) end)
  end

  defp collect_names_in(node, acc), do: do_collect_names(node, acc)

  defp do_collect_names(%{"_type" => "Name", "id" => id}, acc), do: MapSet.put(acc, id)

  defp do_collect_names(node, acc) when is_map(node) do
    node
    |> Map.delete("_type")
    |> Enum.reduce(acc, fn {_k, v}, a -> do_collect_names(v, a) end)
  end

  defp do_collect_names(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &do_collect_names/2)

  defp do_collect_names(_leaf, acc), do: acc

  # Builtins whose presence as a `Name` callee means "pure, doesn't
  # mutate args, will likely be folded away". Passing a tracked Name
  # to one of these does NOT escape it — we'll either fold the call
  # at compile time or the runtime path is itself non-mutating.
  @non_escaping_builtins MapSet.new(~w(print repr str format))

  @doc false
  # Phase 1+3: names passed as an arg to any function call (including
  # method calls on other receivers). Conservative — we don't try to
  # prove whether the callee mutates; any pass-through is treated as
  # an escape that invalidates fold.
  #
  # Exceptions:
  #   * Name in callee position (`N(...)`) — using N as a function,
  #     not a pass-through, so not an escape.
  #   * Call to a `@non_escaping_builtins` callee — args don't escape
  #     because the callee is provably non-mutating (print / repr /
  #     str / format).
  def collect_escapes(body), do: do_collect_escapes(body, MapSet.new())

  defp do_collect_escapes(
         %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => callee}, "args" => args} =
           node,
         acc
       )
       when is_binary(callee) do
    acc =
      if MapSet.member?(@non_escaping_builtins, callee) do
        acc
      else
        Enum.reduce(args, acc, &collect_names_in/2)
      end

    do_collect_escapes_children(node, acc)
  end

  defp do_collect_escapes(%{"_type" => "Call", "args" => args} = node, acc) do
    acc = Enum.reduce(args, acc, &collect_names_in/2)
    do_collect_escapes_children(node, acc)
  end

  defp do_collect_escapes(node, acc) when is_map(node) do
    do_collect_escapes_children(node, acc)
  end

  defp do_collect_escapes(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &do_collect_escapes/2)

  defp do_collect_escapes(_leaf, acc), do: acc

  defp do_collect_escapes_children(node, acc) when is_map(node) do
    node
    |> Map.delete("_type")
    |> Enum.reduce(acc, fn {_k, v}, a -> do_collect_escapes(v, a) end)
  end

  @doc false
  # Phase 2: top-level FunctionDefs whose body is exactly
  # `[<docstring?>, Return(foldable)]`. Maps function name to its
  # constant return value.
  def collect_constant_fns(body) do
    for node <- body,
        match?(%{"_type" => "FunctionDef"}, node),
        {:ok, v} <- [constant_fn_return(node)],
        into: %{} do
      {node["name"], v}
    end
  end

  defp constant_fn_return(%{"body" => body}) do
    stripped =
      case body do
        [%{"_type" => "Expr", "value" => %{"_type" => "Constant", "value" => v}} | rest]
        when is_binary(v) ->
          rest

        other ->
          other
      end

    case stripped do
      [%{"_type" => "Return", "value" => value}] when not is_nil(value) ->
        LiteralFold.fold(value)

      _ ->
        :error
    end
  end

  defp constant_fn_return(_), do: :error

  # ----- Resolve: literal-or-bail recognition -------------------------
  #
  # `resolve/2` is the unified "is this expression statically a known
  # value?" predicate. Used by every emit-site rewriter below.
  #
  #   1. If the node is directly `LiteralFold.fold`-able — return the
  #      BEAM value.
  #   2. If it's `Name(N)` and Phase 1 / Phase 3 gates pass — return
  #      the bound value from `literal_bindings`.
  #   3. If it's `Call(Name(F), args)` and Phase 2 gate passes — return
  #      the function's constant return value.

  defp resolve(node, info) do
    case LiteralFold.fold(node) do
      {:ok, v} -> {:ok, v}
      :error -> resolve_via_flow(node, info)
    end
  end

  defp resolve_via_flow(%{"_type" => "Name", "id" => n}, info) do
    with {:ok, v} <- Map.fetch(info.literal_bindings, n),
         false <- MapSet.member?(info.mutation_sites, n),
         false <- MapSet.member?(info.alias_sites, n),
         false <- MapSet.member?(info.escape_sites, n) do
      {:ok, v}
    else
      _ -> :error
    end
  end

  defp resolve_via_flow(
         %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => f}, "args" => args},
         info
       ) do
    with {:ok, v} <- Map.fetch(info.constant_functions, f),
         true <- Enum.all?(args, &side_effect_free?(&1, info)) do
      {:ok, v}
    else
      _ -> :error
    end
  end

  defp resolve_via_flow(_, _), do: :error

  defp side_effect_free?(node, info), do: match?({:ok, _}, resolve(node, info))

  defp constant_node(binary) when is_binary(binary),
    do: %{"_type" => "Constant", "value" => binary, "kind" => nil}

  # ----- Rewrite pass --------------------------------------------------

  defp rewrite_body(body, info), do: walk(body, info)

  defp walk(node, info) when is_map(node) do
    node
    |> maybe_rewrite_node(info)
    |> walk_children(info)
  end

  defp walk(list, info) when is_list(list), do: Enum.map(list, &walk(&1, info))

  defp walk(leaf, _info), do: leaf

  defp walk_children(node, info) when is_map(node) do
    type = Map.get(node, "_type")

    node
    |> Map.delete("_type")
    |> Enum.map(fn {k, v} -> {k, maybe_walk_child(type, k, v, info)} end)
    |> Map.new()
    |> Map.put("_type", type)
  end

  # `FormattedValue.format_spec` MUST stay a `JoinedStr` (or nil) for
  # the downstream FString lowering to recognize it. Our top-level
  # rewriter would otherwise collapse an all-literal `JoinedStr` to a
  # bare `Constant`, breaking the converter. The full segment fold
  # via `fold_fstring_segment/2` already handles the spec internally
  # when the whole segment is foldable — when it's not, leave the
  # spec untouched.
  defp maybe_walk_child("FormattedValue", "format_spec", v, _info), do: v
  defp maybe_walk_child(_type, _key, v, info), do: walk(v, info)

  # --- Per-shape rewriters ----------------------------------------------

  # `repr(x)` — fold via `LiteralFold.repr_of/1` when `resolve` finds
  # `x`'s value.
  defp maybe_rewrite_node(
         %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => "repr"}, "args" => [arg]} =
           node,
         info
       ) do
    with {:ok, v} <- resolve(arg, info),
         {:ok, repr} <- LiteralFold.repr_of(v) do
      constant_node(repr)
    else
      _ -> node
    end
  end

  # `str(x)` — fold via `LiteralFold.str_of/1`.
  defp maybe_rewrite_node(
         %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => "str"}, "args" => [arg]} =
           node,
         info
       ) do
    with {:ok, v} <- resolve(arg, info),
         {:ok, s} <- LiteralFold.str_of(v) do
      constant_node(s)
    else
      _ -> node
    end
  end

  # `format(x)` — same as `str(x)`.
  defp maybe_rewrite_node(
         %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => "format"}, "args" => [arg]} =
           node,
         info
       ) do
    with {:ok, v} <- resolve(arg, info),
         {:ok, s} <- LiteralFold.str_of(v) do
      constant_node(s)
    else
      _ -> node
    end
  end

  # `format(x, spec)` — delegate to runtime helper at compile time when
  # both value and spec are foldable.
  defp maybe_rewrite_node(
         %{
           "_type" => "Call",
           "func" => %{"_type" => "Name", "id" => "format"},
           "args" => [arg, spec_node]
         } = node,
         info
       ) do
    with {:ok, v} <- resolve(arg, info),
         {:ok, spec} <- resolve(spec_node, info),
         true <- is_binary(spec) do
      constant_node(RuntimeFormat.py_format_value(v, spec))
    else
      _ -> node
    end
  rescue
    # `py_format_value` raises on unsupported spec / type combos; let
    # the runtime path handle those by leaving the node untouched.
    _ -> node
  end

  # `print(arg1, arg2, …, sep=…, end=…)` — fold each arg to its `str()`
  # form when the arg is provably literal. Leave non-foldable args
  # alone. Don't touch sep/end keywords (the Pylixir converter already
  # handles literal kwargs).
  defp maybe_rewrite_node(
         %{
           "_type" => "Call",
           "func" => %{"_type" => "Name", "id" => "print"},
           "args" => args
         } = node,
         info
       ) do
    new_args = Enum.map(args, &maybe_fold_print_arg(&1, info))
    %{node | "args" => new_args}
  end

  # `<lit_str> % <args>` — call the runtime helper at compile time.
  defp maybe_rewrite_node(
         %{
           "_type" => "BinOp",
           "op" => %{"_type" => "Mod"},
           "left" => left,
           "right" => right
         } = node,
         info
       ) do
    with {:ok, fmt} <- resolve(left, info),
         true <- is_binary(fmt),
         {:ok, raw_args} <- resolve(right, info),
         args_list <- normalize_percent_args(raw_args) do
      constant_node(RuntimeHelpers.py_str_percent_format(fmt, args_list, []))
    else
      _ -> node
    end
  rescue
    _ -> node
  end

  # `<lit_str>.format(…)` — fold when the format string and ALL args
  # are foldable. Uses Pylixir's existing `.format()` semantics via
  # `RuntimeHelpers.py_format_value/2` per-segment; for the simple
  # case of `"{} {}".format(a, b)` we can synthesise the result by
  # interpreting `{…}` placeholders ourselves. Keep this conservative
  # — only the bare-`{}` and `{!r}`/`{!s}` shapes are folded; anything
  # with format spec, indexing, or attribute access falls through.
  defp maybe_rewrite_node(
         %{
           "_type" => "Call",
           "func" => %{"_type" => "Attribute", "value" => recv, "attr" => "format"},
           "args" => args,
           "keywords" => []
         } = node,
         info
       ) do
    with {:ok, tmpl} <- resolve(recv, info),
         true <- is_binary(tmpl),
         {:ok, arg_vals} <- resolve_all(args, info),
         {:ok, result} <- fold_simple_format(tmpl, arg_vals) do
      constant_node(result)
    else
      _ -> node
    end
  end

  # `f"…"` — JoinedStr is a list of `Constant` (literal segments) and
  # `FormattedValue` (dynamic segments). Fold the whole thing if every
  # dynamic segment resolves to a literal AND has a literal format
  # spec / conversion we know how to apply.
  defp maybe_rewrite_node(%{"_type" => "JoinedStr", "values" => values} = node, info) do
    case fold_joined_str(values, info) do
      {:ok, s} -> constant_node(s)
      :error -> node
    end
  end

  defp maybe_rewrite_node(node, _info), do: node

  # ----- Helpers --------------------------------------------------------

  defp maybe_fold_print_arg(arg, info) do
    case resolve(arg, info) do
      {:ok, v} ->
        case LiteralFold.str_of(v) do
          {:ok, s} -> constant_node(s)
          :error -> arg
        end

      :error ->
        arg
    end
  end

  defp resolve_all(nodes, info) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn n, {:ok, acc} ->
      case resolve(n, info) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      :error -> :error
    end
  end

  # Python's `%`-format spreads only TUPLES on the right side. Every
  # other type (including lists, dicts, scalars) is a single value
  # passed to the first `%`-spec.
  #
  #   "%s" % (1, 2)     -> "1" (with 2 unused — TypeError actually,
  #                        but our helper tolerates it)
  #   "%s" % [1, 2, 3]  -> "[1, 2, 3]" (list as single value)
  #   "%s" % 5          -> "5"
  defp normalize_percent_args(v) when is_tuple(v), do: Tuple.to_list(v)
  defp normalize_percent_args(v), do: [v]

  # Very small `.format()` interpreter: supports `{}`, `{!r}`, `{!s}`
  # in positional order. Anything else (indexed `{0}`, named `{x}`,
  # format spec `{:>5}`) bails to `:error`.
  defp fold_simple_format(tmpl, args), do: do_fold_format(tmpl, args, [])

  defp do_fold_format("", _args, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp do_fold_format("{{" <> rest, args, acc), do: do_fold_format(rest, args, ["{" | acc])
  defp do_fold_format("}}" <> rest, args, acc), do: do_fold_format(rest, args, ["}" | acc])

  defp do_fold_format("{" <> rest, args, acc) do
    case String.split(rest, "}", parts: 2) do
      [spec, rest_after] ->
        with [arg | rest_args] <- args,
             {:ok, formatted} <- apply_simple_spec(spec, arg) do
          do_fold_format(rest_after, rest_args, [formatted | acc])
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp do_fold_format(<<ch::utf8, rest::binary>>, args, acc),
    do: do_fold_format(rest, args, [<<ch::utf8>> | acc])

  # Spec set supported here:
  #   `""`   → str(arg)
  #   `"!r"` → repr(arg)
  #   `"!s"` → str(arg)
  defp apply_simple_spec("", arg), do: LiteralFold.str_of(arg)
  defp apply_simple_spec("!r", arg), do: LiteralFold.repr_of(arg)
  defp apply_simple_spec("!s", arg), do: LiteralFold.str_of(arg)
  defp apply_simple_spec(_, _), do: :error

  # f-string folding: walk segments. Constants pass through. Formatted
  # values fold only when value + conversion + format_spec are all
  # foldable to a literal string.
  defp fold_joined_str(values, info) do
    Enum.reduce_while(values, {:ok, []}, fn seg, {:ok, acc} ->
      case fold_fstring_segment(seg, info) do
        {:ok, s} -> {:cont, {:ok, [s | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, rev |> Enum.reverse() |> IO.iodata_to_binary()}
      :error -> :error
    end
  end

  defp fold_fstring_segment(%{"_type" => "Constant", "value" => v}, _info) when is_binary(v),
    do: {:ok, v}

  defp fold_fstring_segment(
         %{
           "_type" => "FormattedValue",
           "value" => value_node,
           "conversion" => conversion,
           "format_spec" => format_spec
         },
         info
       ) do
    with {:ok, v} <- resolve(value_node, info),
         {:ok, converted} <- apply_fstring_conversion(conversion, v),
         {:ok, spec_str} <- fold_format_spec(format_spec, info),
         {:ok, formatted} <- apply_fstring_spec(converted, spec_str) do
      {:ok, formatted}
    else
      _ -> :error
    end
  end

  defp fold_fstring_segment(_, _), do: :error

  # CPython's FormattedValue.conversion field — `-1` means no
  # conversion, `115` `s`, `114` `r`, `97` `a` (ascii).
  defp apply_fstring_conversion(-1, v), do: LiteralFold.str_of(v)
  defp apply_fstring_conversion(115, v), do: LiteralFold.str_of(v)
  defp apply_fstring_conversion(114, v), do: LiteralFold.repr_of(v)
  # `!a` (ASCII repr) — not supported; bail.
  defp apply_fstring_conversion(_, _), do: :error

  # `format_spec` is `nil`, OR a `JoinedStr` whose values are entirely
  # literal Constants. Anything more dynamic bails.
  defp fold_format_spec(nil, _info), do: {:ok, ""}

  defp fold_format_spec(%{"_type" => "JoinedStr", "values" => values}, info) do
    fold_joined_str(values, info)
  end

  defp fold_format_spec(_, _info), do: :error

  # Apply a static format spec to an already-converted string. The
  # only spec we fold without bailing is `""` (no formatting); spec'd
  # cases would need the full grammar — punt to runtime.
  defp apply_fstring_spec(converted, "") when is_binary(converted), do: {:ok, converted}
  defp apply_fstring_spec(_converted, _spec), do: :error
end
