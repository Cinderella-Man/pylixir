defmodule Pylixir.Converter do
  @moduledoc """
  Recursive dispatcher that walks a Python AST (decoded JSON map) and emits
  Elixir AST tuples (RFC §3.2).

  The entry point for a `Module` node is `convert/3` — it takes the
  pre-computed `%Pylixir.ModuleAnalysis{}` from `Pylixir.ModuleAnalysis.analyze/1`
  as a third argument so partition/derived facts are computed once and
  threaded in. All other node types are converted via `convert/2`; the
  catch-all clause raises `Pylixir.UnsupportedNodeError`.
  """

  alias Pylixir.AST.{BoolReturning, Trivial}

  alias Pylixir.{
    Builtins,
    Context,
    ControlFlow,
    HelpersCodegen,
    LoopAnalysis,
    Lowering,
    ModuleAnalysis,
    MutableModuleDict,
    Naming,
    Nodes,
    Stdlib,
    TypeInfer,
    UnsupportedNodeError
  }

  @type elixir_ast :: Macro.t()

  @doc """
  Convert a Python `Module` node with its pre-computed analysis. The Module
  clause owns the wrapper-emission shape: helpers + module attributes +
  defp's + `def py_main, do: <runtime>` + trailing `TranslatedCode.py_main()`.
  """
  @spec convert(map(), Context.t(), ModuleAnalysis.t()) :: {elixir_ast(), Context.t()}
  def convert(%{"_type" => "Module"}, context, %ModuleAnalysis{} = analysis) do
    attr_names =
      for {name, _value} <- analysis.module_attrs, into: MapSet.new(), do: name

    class_names =
      for cls <- analysis.class_defs, into: MapSet.new(), do: cls.name

    # method-name → [{class_name, :mutating | :read_only}] map; lets
    # the attribute-call router pick a unique class for a method name.
    # Ambiguous lookups (same method name on multiple classes) are
    # rejected at the call site with a clear hint.
    class_methods =
      Enum.reduce(analysis.class_defs, %{}, fn cls, acc ->
        mutating = class_mutating_methods(cls)

        Enum.reduce(cls.methods, acc, fn m, acc2 ->
          kind = if MapSet.member?(mutating, m.name), do: :mutating, else: :read_only
          Map.update(acc2, m.name, [{cls.name, kind}], &[{cls.name, kind} | &1])
        end)
      end)

    context = %{
      context
      | module_attrs: attr_names,
        class_names: class_names,
        class_methods: class_methods
    }

    # `TypeInfer.module_summary/2`, `TypeInfer.seed_module_attr_types/2`,
    # and `TypeInfer.Signatures.infer/3` now run in `Pylixir.Pipeline`
    # before the Module clause is invoked. The attr_names/class_names/
    # class_methods setup above stays inline because it depends on
    # Converter-private helpers (`class_mutating_methods/1` et al.);
    # the three lifted passes verifiably do NOT read those fields so
    # the reorder is behaviour-preserving.

    {class_asts, context} = convert_class_defs(analysis.class_defs, context)
    {hoisted_asts, context} = emit_hoisted_imports(analysis.hoisted_imports, context)
    {attr_asts, context} = convert_module_attrs(analysis.module_attrs, context)
    {fn_asts, context} = convert_each(analysis.function_defs, context)

    # M5 — `Pylixir.Nodes.Functions.emit_function_def/2` returns a list
    # `[@doc, def]` when a docstring is present. Flatten here so each
    # member appears at module-top scope (Macro.to_string would
    # otherwise wrap a 2-item `__block__` in `(...)`).
    fn_asts =
      Enum.flat_map(fn_asts, fn
        list when is_list(list) -> list
        ast -> [ast]
      end)

    # Runtime statements live inside py_main. FunctionDefs that appear
    # here are either (a) top-level defs demoted by ModuleAnalysis
    # because they close over mutable module state, or (b) Python defs
    # inside control flow (`if cond: def foo()`). Both are correctly
    # emitted as `name = fn ... end` lambda bindings via the
    # `:nested_fn` path — that closes over the surrounding py_main
    # scope, which is what Python's `def` semantics require here.
    # Module-top freezable names (alist optimisation, P4) — runtime
    # statements form the body of the synthetic `py_main` scope, so
    # the safety check runs over them just like a regular function
    # body. Restored after the conversion. The set is consulted by
    # `Pylixir.Nodes.Assign` when P5 lands.
    saved_freezable_names = context.freezable_names
    saved_append_build_names = context.append_build_names
    saved_append_build_type_refinable = context.append_build_type_refinable
    saved_append_build_element_types = context.append_build_element_types
    saved_append_build_freeze_after = context.append_build_freeze_after
    saved_pvec_names = context.pvec_names

    {append_names, append_freeze_after} =
      Pylixir.AppendBuildAnalysis.analyze(analysis.runtime_statements)

    append_type_refinable =
      Pylixir.AppendBuildAnalysis.type_refinable_names(analysis.runtime_statements)

    context = %{
      context
      | def_position: :nested_fn,
        freezable_names: Pylixir.AlistAnalysis.freezable_names(analysis.runtime_statements),
        append_build_names: append_names,
        append_build_type_refinable: append_type_refinable,
        append_build_element_types: %{},
        append_build_freeze_after: append_freeze_after,
        pvec_names: Pylixir.PvecAnalysis.analyze(analysis.runtime_statements)
    }

    {stmt_asts, context} = convert_each_with_freezes(analysis.runtime_statements, context)

    context = %{
      context
      | def_position: :module_top,
        freezable_names: saved_freezable_names,
        append_build_names: saved_append_build_names,
        append_build_type_refinable: saved_append_build_type_refinable,
        append_build_element_types: saved_append_build_element_types,
        append_build_freeze_after: saved_append_build_freeze_after,
        pvec_names: saved_pvec_names
    }

    # M3 — drop empty `{:__block__, [], []}` and noop sentinels that
    # surface as stray `nil` lines in the output (e.g. a hoisted
    # `from functools import reduce` has no runtime alias left to
    # bind, but currently still returns an empty block).
    stmt_asts =
      Enum.reject(stmt_asts, fn
        {:__block__, _, []} -> true
        nil -> true
        _ -> false
      end)

    py_main = py_main_def(stmt_asts, analysis.uses_exit)

    # N2 — drop hoisted defps that the user code never references.
    # After N2's reduce-inline path lands, `reduce` calls become
    # `Enum.reduce/3` inline and the hoisted wrapper is dead. Same
    # cascade applies to any other hoisted alias whose call sites all
    # got inlined elsewhere.
    user_code = class_asts ++ fn_asts ++ context.while_helpers ++ [py_main]
    hoisted_asts = drop_unused_hoisted(hoisted_asts, user_code)

    emitted =
      attr_asts ++
        hoisted_asts ++
        user_code

    helpers =
      HelpersCodegen.helpers_ast_for(emitted,
        drop_float: not analysis.uses_float,
        drop_tuple_clause: not analysis.uses_tuple,
        drop_set_clause: not analysis.uses_set,
        drop_dict_clause: not analysis.uses_dict
      )

    moduledoc = moduledoc_ast(analysis.module_doc)

    body_block = moduledoc ++ helpers ++ emitted

    defmodule_ast =
      {:defmodule, [],
       [
         {:__aliases__, [], [:TranslatedCode]},
         [do: {:__block__, [], body_block}]
       ]}

    trailing_call =
      {{:., [], [{:__aliases__, [], [:TranslatedCode]}, :py_main]}, [], []}

    {{:__block__, [], [defmodule_ast, trailing_call]}, context}
  end

  @doc """
  Convert a single Python AST node to an Elixir AST tuple.

  Returns `{elixir_ast, updated_context}`. Threads the context through
  recursive calls so nested constructs can update scope / counters.
  """
  @spec convert(map(), Context.t()) :: {elixir_ast(), Context.t()}
  def convert(%{"_type" => "UnaryOp", "op" => %{"_type" => "Not"}, "operand" => operand}, context) do
    # `not x` — try type-aware emit (e.g. `x == ""` when x is :str)
    # before falling back to the polymorphic `!truthy?(x)`. Keeps the
    # rest of the unary ops on the simpler ast-only dispatch.
    operand_type = TypeInfer.infer_expr(operand, context)
    {operand_ast, context} = convert(operand, context)

    {typed_truthy_test(operand_ast, operand_type, :negative) ||
       {:!, [], [{:truthy?, [], [operand_ast]}]}, context}
  end

  def convert(%{"_type" => "UnaryOp", "op" => op, "operand" => operand} = node, context) do
    {operand_ast, context} = convert(operand, context)
    {unary_op_ast(op, operand_ast, node), context}
  end

  def convert(%{"_type" => "BinOp", "op" => op, "left" => left, "right" => right} = node, context) do
    lt = TypeInfer.infer_expr(left, context)
    rt = TypeInfer.infer_expr(right, context)
    {left_ast, context} = convert(left, context)
    {right_ast, context} = convert(right, context)
    {bin_op_ast(op, left_ast, right_ast, node, lt, rt), context}
  end

  def convert(%{"_type" => "Pass"}, context), do: {:ok, context}

  # `global x` / `nonlocal x` declarations — pure scope hints to
  # Python's name resolution. Pylixir's `global` shape is supported
  # via `Context.mutable_module_dicts` (the Process dict routing
  # handles cross-scope mutation regardless of where the declaration
  # appears). `nonlocal` is supported via the same dictionary when
  # the captured outer-binding name has been promoted. The bare
  # statement itself emits `:ok` (a no-op Elixir atom).
  def convert(%{"_type" => "Global"}, context), do: {:ok, context}
  def convert(%{"_type" => "Nonlocal"}, context), do: {:ok, context}

  # `raise ExceptionClass(args)` / `raise ExceptionClass` / bare
  # `raise` — Python's exception-raising. Pylixir doesn't model
  # exception classes, so we route everything through
  # `RuntimeError` and stringify the message: `raise X("msg")` lowers
  # to `raise(RuntimeError, "X: msg")`. Bare `re-raise` (`raise` with
  # no exc inside an except) is rejected — it needs the original
  # exception's binding which we don't track.
  def convert(%{"_type" => "Raise", "exc" => exc}, context) do
    case exc do
      nil ->
        raise UnsupportedNodeError,
          node_type: "Raise",
          hint: "bare `raise` (re-raise) is not supported — name the exception explicitly"

      %{"_type" => "Call", "func" => %{"_type" => "Name", "id" => cls}, "args" => args} ->
        emit_raise(cls, args, context)

      %{"_type" => "Name", "id" => cls} ->
        emit_raise(cls, [], context)

      other ->
        raise UnsupportedNodeError,
          node_type: "Raise",
          hint:
            "raise target must be `ClassName(...)` or `ClassName`; got `#{Map.get(other, "_type")}`"
    end
  end

  # Walrus operator (PEP 572): `(n := expr)` is both an assignment
  # AND an expression that yields the assigned value. Elixir's `=`
  # already has both shapes — `(n = 5) > 0` works directly. The Name
  # target binds in the surrounding scope (Pylixir treats it like an
  # Assign — `bind_name` records it).
  def convert(%{"_type" => "NamedExpr", "target" => target, "value" => value}, context) do
    case target do
      %{"_type" => "Name", "id" => id} ->
        value_type = TypeInfer.infer_expr(value, context)
        {value_ast, context} = convert(value, context)
        context = TypeInfer.bind(context, id, value_type)
        context = bind_name(context, id)
        target_atom = id |> Naming.rewrite() |> String.to_atom()
        {{:=, [], [{target_atom, [], nil}, value_ast]}, context}

      other ->
        raise UnsupportedNodeError,
          node_type: "NamedExpr",
          hint:
            "walrus target must be a bare Name (`(n := expr)`); got `#{Map.get(other, "_type")}`"
    end
  end

  # `del coll[k]` — rebind `coll` via `py_delitem` (polymorphic on
  # list/map/MapSet). Multi-target `del a, b` becomes a block. Other
  # target shapes (bare Name `del x`, Attribute, Tuple) still raise.
  def convert(%{"_type" => "Delete", "targets" => targets} = node, context) do
    {asts, context} =
      Enum.reduce(targets, {[], context}, fn target, {acc, ctx} ->
        {ast, ctx} = convert_del_target(target, node, ctx)
        {[ast | acc], ctx}
      end)

    body =
      case Enum.reverse(asts) do
        [single] -> single
        many -> {:__block__, [], many}
      end

    {body, context}
  end

  def convert(%{"_type" => "Assert", "test" => test} = node, context) do
    {test_ast, context} = convert_test(test, context)

    msg_ast =
      case Map.get(node, "msg") do
        nil ->
          "AssertionError"

        msg ->
          {ast, _} = convert(msg, context)
          ast
      end

    raise_call =
      {:raise, [], [{{:., [], [{:__aliases__, [], [:RuntimeError]}, :exception]}, [], [msg_ast]}]}

    {{:unless, [], [test_ast, [do: raise_call]]}, context}
  end

  # Imports are no-ops in generated Elixir — `Pylixir.Stdlib` modules
  # supply their own translations at attribute / call sites. Reject any
  # module name the registry doesn't know about. `functools` is
  # accepted as a no-op so the user's `@functools.lru_cache` decorator
  # path resolves (the decorator itself is stripped at the def site).
  @import_no_ops ~w(functools)

  def convert(%{"_type" => "Import", "names" => names}, context) do
    case Enum.find(names, fn %{"name" => n} ->
           not Stdlib.supported?(n) and n not in @import_no_ops
         end) do
      nil ->
        {{:__block__, [], []}, context}

      %{"name" => unknown} ->
        raise UnsupportedNodeError,
          node_type: "Import",
          hint:
            "no stdlib translation for `import #{unknown}` (known: #{Enum.join(Stdlib.names(), ", ")})"
    end
  end

  def convert(%{"_type" => "ImportFrom", "module" => "__future__"}, context),
    do: {{:__block__, [], []}, context}

  # `from functools import lru_cache, cache, reduce` — decorator
  # no-ops (Pylixir doesn't memoize) and `reduce` (handled at the
  # call site). `cmp_to_key` is the exception: it's a real runtime
  # value because `sorted(xs, key=cmp_to_key(f))` must reach the
  # `Enum.sort` path with a comparator instead of `Enum.sort_by`
  # with a key function. Bind it as a lambda that tags its arg
  # `{:py_cmp_to_key, cmp}`; the runtime `py_sorted_by/2` helper
  # pattern-matches the tag.
  def convert(%{"_type" => "ImportFrom", "module" => "functools", "names" => names}, context) do
    allowed = ~w(lru_cache cache reduce cmp_to_key)

    unknown = Enum.find(names, fn %{"name" => n} -> n not in allowed end)

    if unknown do
      raise UnsupportedNodeError,
        node_type: "ImportFrom",
        hint:
          "`from functools import #{unknown["name"]}` is not supported (allowed: #{Enum.join(allowed, ", ")})"
    end

    # Each imported name that has a real runtime value (not a no-op
    # decorator like lru_cache / cache) gets bound as a lambda.
    # `cmp_to_key` tags its arg `{:py_cmp_to_key, cmp}` for sorted's
    # routing. `reduce` shims Python's `functools.reduce(fn, iter[, init])`
    # via Elixir's `Enum.reduce/3` — but only when NOT hoisted to a
    # module-top defp (see `emit_hoisted_imports/2`); hoisted names
    # are already module-level so the runtime binding here would
    # shadow them with a py_main local. The hoisted-name check
    # mirrors the ImportFrom-stdlib path.
    runtime_aliases =
      Enum.filter(names, fn %{"name" => n} = entry ->
        alias_name = Map.get(entry, "asname") || n
        already_hoisted? = Map.has_key?(context.known_function_arities, alias_name)
        n in ~w(cmp_to_key reduce) and not already_hoisted?
      end)

    case runtime_aliases do
      [] ->
        {{:__block__, [], []}, context}

      [%{"name" => "reduce"} = entry] ->
        alias_name = Map.get(entry, "asname") || "reduce"
        atom = alias_name |> Naming.rewrite() |> String.to_atom()
        # `reduce(fn, iter, init)` — Python's signature. Elixir's
        # `Enum.reduce/3` takes `(iter, init, fn(x, acc))`, so we
        # flip both the arg order and the inner-fn arg order.
        # (2-arg `reduce(fn, iter)` form not supported here; an `fn`
        # clause can't mix arities.)
        lambda =
          {:fn, [],
           [
             {:->, [],
              [
                [{:fn_arg, [], nil}, {:iter, [], nil}, {:init, [], nil}],
                {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [],
                 [
                   {:iter, [], nil},
                   {:init, [], nil},
                   {:fn, [],
                    [
                      {:->, [],
                       [
                         [{:x, [], nil}, {:acc, [], nil}],
                         {{:., [], [{:fn_arg, [], nil}]}, [], [{:acc, [], nil}, {:x, [], nil}]}
                       ]}
                    ]}
                 ]}
              ]}
           ]}

        assign = {:=, [], [{atom, [], nil}, lambda]}
        context = bind_name(context, alias_name)
        {assign, context}

      [%{"name" => "cmp_to_key"} = entry] ->
        alias_name = Map.get(entry, "asname") || "cmp_to_key"
        atom = alias_name |> Naming.rewrite() |> String.to_atom()

        lambda =
          {:fn, [],
           [
             {:->, [],
              [
                [{:cmp, [], nil}],
                {:{}, [], [:py_cmp_to_key, {:cmp, [], nil}]}
              ]}
           ]}

        assign = {:=, [], [{atom, [], nil}, lambda]}
        context = bind_name(context, alias_name)
        {assign, context}
    end
  end

  # `from <stdlib_mod> import <names>` — delegates the per-name RHS
  # shape to `<Stdlib.Module>.import_binding/1`. Stdlib modules own
  # whether each name is a value-binding, a `&capture/N`, or a
  # sentinel-`nil` for downstream alias-rewrite. Adding a stdlib that
  # supports from-import is one file edit, not a Converter change.
  def convert(%{"_type" => "ImportFrom", "module" => mod, "names" => names} = node, context) do
    case Stdlib.impl(mod) do
      nil ->
        raise UnsupportedNodeError,
          node_type: "ImportFrom",
          hint:
            "`from #{mod} import ...` is not supported (only `from __future__`; for stdlib modules use `import #{mod}` and reference via `#{mod}.<name>`)",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      impl ->
        {stmts, context} =
          Enum.reduce(names, {[], context}, fn entry, {acc, ctx} ->
            n = entry["name"]
            alias = entry["asname"] || n

            # Hoisted imports were emitted as module-top defps by
            # `emit_hoisted_imports/2`. Skip the runtime binding —
            # the call site routes to the defp via the
            # `known_functions` check in `emit_name_call`. Still
            # register the alias→stdlib mapping so call-site arity
            # mismatch routing (`stdlib_aliases`) keeps working.
            if Map.has_key?(ctx.known_function_arities, alias) and
                 MapSet.member?(ctx.known_functions, alias) do
              ctx = %{ctx | stdlib_aliases: Map.put(ctx.stdlib_aliases, alias, {mod, n})}
              {[{:__block__, [], []} | acc], ctx}
            else
              {stmt, ctx} = stdlib_from_import_alias(mod, impl, n, alias, ctx, node)
              {[stmt | acc], ctx}
            end
          end)

        body =
          case Enum.reverse(stmts) do
            [] -> {:__block__, [], []}
            [single] -> single
            many -> {:__block__, [], many}
          end

        {body, context}
    end
  end

  # Minimal Call clause — supports `Name(args)` calls only. T28 will
  # generalize to `Attribute` calls, builtins, math, kwargs, local-scope
  # shadowing precedence with explicit `.(args)` for shadowed names.
  def convert(%{"_type" => "Call"} = node, context) do
    case detect_next_iter(node) do
      {:ok, inner, default} ->
        emit_next_iter(inner, default, context)

      :no ->
        case node["func"] do
          %{"_type" => "Name", "id" => id} ->
            emit_name_call(id, node, context)

          %{"_type" => "Attribute", "value" => target, "attr" => attr} ->
            emit_attribute_call(target, attr, node, context)

          # Chained-call shape: `f(x)(y)`, `make()(arg)`,
          # `(lambda x: x+1)(5)`. The func is itself a
          # Call/Lambda/Subscript that returns a callable. Emit
          # `(callable_ast).(args)` — Elixir's anonymous-call
          # invocation. No-kwargs only (consistent with the in-scope
          # lambda call path).
          %{"_type" => type} when type in ["Call", "Lambda", "Subscript", "IfExp"] ->
            emit_dynamic_call(node, context)

          _ ->
            raise UnsupportedNodeError,
              node_type: "Call",
              hint:
                "unsupported call-target shape `#{Map.get(node["func"], "_type")}`; expected `Name` or `Attribute`",
              lineno: Map.get(node, "lineno"),
              col_offset: Map.get(node, "col_offset")
        end
    end
  end

  # Bare `Attribute` access (no Call). Walk the chain — if it roots at a
  # known stdlib module, dispatch to its `attribute/2` callback; otherwise
  # the access shape isn't supported (Pylixir has no general
  # object-attribute semantics).
  def convert(%{"_type" => "Attribute"} = node, context) do
    case stdlib_chain(node) do
      {:ok, mod_name, path} ->
        impl = Stdlib.impl(mod_name)

        Lowering.dispatch(
          impl.attribute(path, node),
          "`#{mod_name}.#{Enum.join(path, ".")}` is not a supported stdlib attribute",
          node,
          context
        )

      :no_stdlib ->
        attr = Map.fetch!(node, "attr")

        case detect_type_name_access(node) do
          {:ok, value_node} ->
            # `type(x).__name__` — the only "attribute on a runtime value"
            # shape we support. Lowers to `py_type_name(x)` which returns
            # Python's class name as a string ("int", "list", ...).
            {value_ast, context} = convert(value_node, context)
            {{:py_type_name, [], [value_ast]}, context}

          :no ->
            # First-pass class lowering treats `obj.<attr>` reads as
            # `Map.fetch!(obj, :<attr>)` whenever a class is in scope
            # (instance state is represented as a plain map). Pylixir
            # doesn't yet track which name is an instance of which
            # class — so the routing fires for ALL non-stdlib name
            # reads when classes are defined in the module. For code
            # without classes, the rejection below still fires
            # unchanged. The runtime `Map.fetch!` raises a `KeyError`
            # equivalent if the name isn't actually an instance map.
            value = node["value"]
            value_type = Map.get(value, "_type")

            cond do
              MapSet.size(context.class_names) > 0 and
                  value_type in ["Name", "Attribute", "Subscript"] ->
                # Depth-N attribute read: `obj.outer.inner.…` lowers to
                # `Map.fetch!(Map.fetch!(obj, :outer), :inner)`. Recursive
                # via the inner Attribute case. Pylixir doesn't track
                # aliasing — chained reads return the field values as
                # of the most recent rebind of the root. `Subscript` is
                # included so `xs[i].attr` / `m[i][j].attr` reads work
                # for adjacency-list / network-flow shapes — the inner
                # Subscript lowers to `py_getitem(...)`.
                {value_ast, context} = convert(value, context)
                attr_atom = String.to_atom(attr)

                {{{:., [], [{:__aliases__, [], [:Map]}, :fetch!]}, [], [value_ast, attr_atom]},
                 context}

              true ->
                raise UnsupportedNodeError,
                  node_type: "Attribute",
                  hint:
                    "attribute access on a non-stdlib value (`<#{value_type}>.#{attr}`) is not supported (known stdlib modules: #{Enum.join(Stdlib.names(), ", ")})",
                  lineno: Map.get(node, "lineno"),
                  col_offset: Map.get(node, "col_offset")
            end
        end
    end
  end

  def convert(%{"_type" => "Return"} = node, context) do
    case context.return_mode do
      nil ->
        raise UnsupportedNodeError,
          node_type: "Return",
          hint: "`return` outside a function is a Python SyntaxError",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      :unwrapped ->
        case Map.get(node, "value") do
          nil -> {nil, context}
          value -> convert(value, context)
        end

      :wrapped ->
        {value_ast, context} =
          case Map.get(node, "value") do
            nil -> {nil, context}
            value -> convert(value, context)
          end

        {ControlFlow.throw_return(value_ast), context}

      :tuple_with_self ->
        # Mutating class methods return `{return_value, updated_self}`
        # so the caller can both receive the value AND see the mutated
        # instance. The caller-side destructure happens in the Expr
        # clause (statement form: `{_, obj} = ...`) and the Assign
        # clause (value form: `{x, obj} = ...`).
        {value_ast, context} =
          case Map.get(node, "value") do
            nil -> {nil, context}
            value -> convert(value, context)
          end

        self_atom = "self" |> Naming.rewrite() |> String.to_atom()
        {{value_ast, {self_atom, [], nil}}, context}
    end
  end

  def convert(%{"_type" => "FunctionDef"} = node, context),
    do: Nodes.Functions.function_def(node, context)

  # A ClassDef encountered while converting a function body has
  # already been hoisted by `ModuleAnalysis.extract_classes/1` to a
  # top-level `defp __cls_<Class>_*` set. Emit an empty block here
  # so the body-block builder doesn't choke on a `nil`. The class is
  # globally callable via its name from any function in the module.
  def convert(%{"_type" => "ClassDef"}, context), do: {{:__block__, [], []}, context}

  def convert(%{"_type" => "ListComp", "elt" => elt, "generators" => generators}, context) do
    Nodes.Comprehension.emit(:list, elt, generators, context)
  end

  def convert(%{"_type" => "SetComp", "elt" => elt, "generators" => generators}, context) do
    Nodes.Comprehension.emit(:set, elt, generators, context)
  end

  def convert(%{"_type" => "GeneratorExp", "elt" => elt, "generators" => generators}, context) do
    Nodes.Comprehension.emit(:gen, elt, generators, context)
  end

  def convert(
        %{"_type" => "DictComp", "key" => key, "value" => value, "generators" => generators},
        context
      ) do
    Nodes.Comprehension.emit(:dict, {key, value}, generators, context)
  end

  def convert(%{"_type" => "Subscript", "value" => value, "slice" => slice}, context) do
    case slice do
      %{"_type" => "Slice"} = slice_node ->
        {value_ast, context} = convert(value, context)
        {start_ast, context} = convert_optional(Map.get(slice_node, "lower"), context)
        {stop_ast, context} = convert_optional(Map.get(slice_node, "upper"), context)
        {step_ast, context} = convert_optional(Map.get(slice_node, "step"), context)
        {{:py_slice, [], [value_ast, start_ast, stop_ast, step_ast]}, context}

      _ ->
        # T5 op-narrowing: a proven `{:list, _}` value reads natively via
        # `Enum.at/2` — exactly what `py_getitem`'s list clause dispatches
        # to (same negative-index / out-of-range behaviour). pvec/alist
        # reps are NOT `is_list?` so they keep `py_getitem` (and their
        # specializations). Infer before convert (which may refine types).
        value_type = TypeInfer.infer_expr(value, context)
        {value_ast, context} = convert(value, context)
        {slice_ast, context} = convert(slice, context)

        if TypeInfer.is_list?(value_type) do
          {{{:., [], [{:__aliases__, [], [:Enum]}, :at]}, [], [value_ast, slice_ast]}, context}
        else
          {{:py_getitem, [], [value_ast, slice_ast]}, context}
        end
    end
  end

  def convert(%{"_type" => "Lambda"} = node, context),
    do: Nodes.Functions.lambda(node, context)

  def convert(%{"_type" => "While"} = node, context),
    do: Nodes.Loop.while_(node, context)

  def convert(%{"_type" => "For"} = node, context),
    do: Nodes.Loop.for_(node, context)

  def convert(%{"_type" => "Break"} = node, context),
    do: Nodes.Loop.break_(node, context)

  def convert(%{"_type" => "Continue"} = node, context),
    do: Nodes.Loop.continue_(node, context)

  # `try: body except [Type] [as e]: handler` — minimal lowering that
  # ignores the exception type / `as`-binding and rescues any raise.
  # `else` runs only when body completes without raising; `finally`
  # always runs (and runs even after a re-raise from the rescue path).
  # This is good enough for the common "catch ValueError / KeyError /
  # IndexError to fall back to a default" patterns in competitive code.
  def convert(%{"_type" => "Try"} = node, context) do
    %{"body" => body, "handlers" => handlers} = node
    orelse = Map.get(node, "orelse", [])
    finalbody = Map.get(node, "finalbody", [])

    # PR 11 — Try branches type-isolated like If: snapshot pre-Try
    # types, let inner converters specialize, restore on exit.
    saved_types = context.types

    # Compute the set of names assigned inside the try body (and
    # `else`) BEFORE conversion — this is the set of bindings that
    # need to escape the Elixir `try do ... end` scope. Without
    # threading them out, code like
    #   try: fact = ...
    #   except: ...
    #   q = fact // p
    # fails to compile because `fact` is bound only inside the try
    # scope and the post-try read sees an undefined variable.
    pre_try_context = context

    assigned =
      (body ++ orelse)
      |> LoopAnalysis.analyze()
      |> Map.get(:assigned_vars)
      |> MapSet.to_list()
      |> Enum.sort()
      # Only thread out names NOT already bound in the surrounding
      # scope — those already-bound names would shadow the outer
      # value with `nil` on the rescue path. (Outer bindings stay
      # outer; only NEW names get the bind-or-nil treatment.)
      |> Enum.reject(&var_bound?(pre_try_context, &1))

    {body_asts, context} = convert_each(body, context)
    body_block = body_to_block(body_asts)

    {body_block, context} =
      case orelse do
        [] ->
          {body_block, context}

        _ ->
          {else_asts, context} = convert_each(orelse, context)
          else_block = body_to_block(else_asts)
          {body_to_block([body_block, else_block]), context}
      end

    body_block = append_binding_tuple(body_block, assigned)

    {rescue_clauses, context} =
      Enum.map_reduce(handlers, context, fn handler, ctx ->
        {handler_asts, ctx} = convert_each(handler["body"] || [], ctx)
        handler_block = body_to_block(handler_asts)
        # Catch-any pattern; ignore the type (Pylixir doesn't track
        # exception classes) and the optional `as e` binding (the
        # user's `e` would shadow our pinned `_`).
        #
        # Pre-bind every threaded name to `nil` so the appended
        # binding tuple references defined variables even when the
        # handler short-circuits (e.g. `except: return default` —
        # `return` lowers to a throw, so the binding tuple is
        # unreachable at runtime but still gets compile-time
        # variable resolution). Handler-side assignments rebind the
        # nils; Elixir treats rebinding as plain reassignment, no
        # shadow warning.
        handler_block = prepend_nil_bindings(handler_block, assigned)
        handler_block = append_binding_tuple(handler_block, assigned)
        {{:->, [], [[{:_, [], nil}], handler_block]}, ctx}
      end)

    {try_args, context} =
      case {rescue_clauses, finalbody} do
        {[], []} ->
          {[do: body_block], context}

        {_, []} ->
          {[do: body_block, rescue: rescue_clauses], context}

        {[], _} ->
          {after_asts, context} = convert_each(finalbody, context)
          after_block = body_to_block(after_asts)
          {[do: body_block, after: after_block], context}

        {_, _} ->
          {after_asts, context} = convert_each(finalbody, context)
          after_block = body_to_block(after_asts)
          {[do: body_block, rescue: rescue_clauses, after: after_block], context}
      end

    try_expr = {:try, [], [try_args]}

    {result_ast, context} =
      case assigned do
        [] ->
          {try_expr, context}

        _ ->
          # Pattern-match the try expression's result into the outer
          # scope so the assigned names survive the try boundary.
          # `_try_value` discards the body's tail expression value (we
          # only care about the bindings). Bind each name in the
          # surrounding context too.
          names = Enum.map(assigned, &name_atom_ref/1)
          pattern = tuple_pattern([{:_try_value, [], nil} | names])
          context = Enum.reduce(assigned, context, fn n, ctx -> bind_name(ctx, n) end)
          {{:=, [], [pattern, try_expr]}, context}
      end

    {result_ast, %{context | types: saved_types}}
  end

  # Expr: drop the result unless the inner value is a recognised
  # mutation method, in which case T30 rewrites it to a target
  # reassignment. Also handles the heapq statement idiom
  # `heapq.heappush(heap, item)` / `heapq.heapify(heap)` — both
  # mutate `heap` in Python and need a rebind in Pylixir.
  def convert(%{"_type" => "Expr", "value" => value}, context) do
    case Pylixir.Stdlib.Heapq.statement_mutation_call(value, context) do
      {:ok, heap_name, fn_name, args} ->
        emit_heapq_statement_rebind(heap_name, fn_name, args, context)

      :none ->
        case Pylixir.Stdlib.Bisect.statement_mutation_call(value, context) do
          {:ok, list_name, method, args} ->
            emit_bisect_insort_rebind(list_name, method, args, context)

          :none ->
            convert_expr_continue(value, context)
        end
    end
  end

  def convert(%{"_type" => "If", "test" => test, "body" => body, "orelse" => orelse}, context) do
    # M2 — compile-time tautology const-fold. If the test resolves to
    # a known constant comparison (e.g. `__name__ == "__main__"`, which
    # is always true in Pylixir's runtime model) or to a typed-isinstance
    # whose target's lattice type matches the spec, emit just the body
    # or orelse directly. Skips the `if … do … end` wrapper.
    case const_fold_if_test(test, context) do
      {:ok, true} -> convert_body_inline(body, context)
      {:ok, false} -> convert_body_inline(orelse, context)
      :unknown -> convert_if_runtime(test, body, orelse, context)
    end
  end

  def convert(%{"_type" => "IfExp", "test" => test, "body" => body, "orelse" => orelse}, context) do
    # Const-fold isinstance/Compare tests when the operand types are
    # statically known. Mirrors the If-statement clause's M2 path.
    case const_fold_if_test(test, context) do
      {:ok, true} -> convert(body, context)
      {:ok, false} -> convert(orelse, context)
      :unknown -> convert_ifexp_runtime(test, body, orelse, context)
    end
  end

  def convert(%{"_type" => "Assign"} = node, context),
    do: Nodes.Assign.assign(node, context)

  def convert(
        %{"_type" => "AugAssign", "target" => target, "op" => op, "value" => value} = node,
        context
      ) do
    aug_assign(target, op, value, node, context)
  end

  def convert(%{"_type" => "BoolOp", "op" => op, "values" => values} = node, context) do
    # Python's `and` / `or` short-circuit AND return the actual operand
    # value, with falsy = `{0, 0.0, "", [], {}, MapSet.new(), nil,
    # False}`. Elixir's `&&` / `||` only treat `false` / `nil` as falsy
    # — so `[] && x` returns `x` in Elixir but `[]` in Python. For
    # statically-bool operands the two match exactly (and the fast
    # native operators stay; cheap inside hot loops). For everything
    # else fall back to a `case` + `truthy?` emission that mirrors
    # Python's value-returning short-circuit.
    op_atom = bool_op_atom(op, node)

    all_bool? =
      Enum.all?(values, fn v -> TypeInfer.infer_expr(v, context) == {:bool} end)

    {asts, context} = convert_each(values, context)
    [first | rest] = asts

    fold =
      if all_bool? do
        Enum.reduce(rest, first, fn ast, acc -> {op_atom, [], [acc, ast]} end)
      else
        Enum.reduce(rest, first, fn ast, acc -> py_short_circuit(op_atom, acc, ast) end)
      end

    {fold, context}
  end

  def convert(
        %{"_type" => "Compare", "left" => left, "ops" => ops, "comparators" => comparators},
        context
      ) do
    Nodes.Compare.emit(left, ops, comparators, context)
  end

  def convert(%{"_type" => "List", "elts" => elts}, context) do
    reject_starred!(elts, "List")
    {asts, context} = convert_each(elts, context)
    {asts, context}
  end

  # Python's `{1, 2, 3}` set literal — lowered to `MapSet.new([…])`.
  # The empty-set case `{}` is a *Dict* in Python AST, not a Set, so
  # this clause always has at least one element.
  def convert(%{"_type" => "Set", "elts" => elts}, context) do
    reject_starred!(elts, "Set")
    {asts, context} = convert_each(elts, context)
    {{{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], [asts]}, context}
  end

  def convert(%{"_type" => "Tuple", "elts" => elts}, context) do
    reject_starred!(elts, "Tuple")
    {asts, context} = convert_each(elts, context)

    tuple_ast =
      case asts do
        [a, b] -> {a, b}
        _ -> {:{}, [], asts}
      end

    {tuple_ast, context}
  end

  def convert(%{"_type" => "Dict", "keys" => keys, "values" => values}, context) do
    # `keys` may include `nil` entries — those mark dict-unpack
    # positions (`{**other_d, "k": v}`); the corresponding `values`
    # entry is the dict to spread. Lower the whole expression to a
    # chain of `Map.merge` (or a single literal map when no unpack).
    if Enum.any?(keys, &is_nil/1) do
      emit_dict_with_unpack(keys, values, context)
    else
      {key_asts, context} = convert_each(keys, context)
      {value_asts, context} = convert_each(values, context)
      pairs = Enum.zip(key_asts, value_asts)
      {{:%{}, [], pairs}, context}
    end
  end

  def convert(%{"_type" => "Name"} = node, context) do
    id = Map.fetch!(node, "id")

    cond do
      id == "__name__" ->
        {"__main__", context}

      Naming.reserved_prefix?(id) ->
        raise UnsupportedNodeError,
          node_type: "Name",
          hint:
            "Python identifier `#{id}` starts with a reserved Pylixir prefix (`var_`/`py_`) — rename it",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      # A local binding (lambda/comp/for-target/Assign) shadows a
      # module attribute. Check `name_in_scope?` BEFORE module_attrs:
      # `x = 99; any(x > 3 for x in xs)` would otherwise resolve the
      # comp's `x` reference to `@var_x` (== 99), giving the wrong
      # answer for every element.
      name_in_scope?(context, id) ->
        atom = id |> Naming.rewrite() |> String.to_atom()
        {{atom, [], nil}, context}

      MapSet.member?(context.mutable_module_dicts, id) ->
        # Module-level dict that gets `name[k] = v`-mutated inside a
        # def — read via Process dict so the mutation persists. The
        # initial `name = {…}` Assign at module-runtime position
        # writes to the same key (see `aug_or_subscript_assign`'s
        # mutable-dict branch).
        {MutableModuleDict.get_ast(id), context}

      MapSet.member?(context.module_attrs, id) ->
        attr_name = String.to_atom("var_" <> id)
        {{:@, [], [{attr_name, [], nil}]}, context}

      Builtins.unary_capturable?(id) ->
        {Builtins.unary_capture(id), context}

      arity = Map.get(context.known_function_arities, id) ->
        # Top-level `def f(args)` referenced as a VALUE (not called):
        # `lambda f: identity`, `map(int, xs)`, `sorted(xs, key=hash)`.
        # Emit `&f/arity` so Elixir treats it as a callable function
        # value; without this the bare name `f` is a variable lookup
        # and fails compilation with "undefined variable".
        atom = id |> Naming.rewrite() |> String.to_atom()
        {{:&, [], [{:/, [], [{atom, [], nil}, arity]}]}, context}

      true ->
        atom = id |> Naming.rewrite() |> String.to_atom()
        {{atom, [], nil}, context}
    end
  end

  def convert(%{"_type" => "JoinedStr"} = node, context),
    do: Nodes.FString.joined_str(node, context)

  def convert(%{"_type" => "Constant"} = node, context) do
    case Map.fetch!(node, "value") do
      %{"_unsupported_literal" => kind} = tagged ->
        raise UnsupportedNodeError,
          node_type: "Constant",
          hint: unsupported_literal_hint(kind, tagged),
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")

      value when is_integer(value) or is_float(value) or is_binary(value) ->
        {value, context}

      value when is_boolean(value) or is_nil(value) ->
        {value, context}

      # Bytes literals (`b'\x00'` / `b'abc'`) serialise as a list of
      # unsigned 8-bit ints — the same shape `bytearray(iter)` produces.
      # The Elixir AST literal for a list of ints is just the list,
      # which `Macro.escape/1` would also produce. Emit directly so
      # subscript reads/writes / slice-assign work uniformly with
      # the list-backed bytearray rep.
      value when is_list(value) ->
        {value, context}

      other ->
        raise UnsupportedNodeError,
          node_type: "Constant",
          hint: "unrecognised constant value shape: #{inspect(other, limit: 3)}",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  def convert(%{"_type" => type} = node, _context) do
    raise UnsupportedNodeError,
      node_type: type,
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # --- Hoisted stdlib imports ------------------------------------------
  #
  # `ModuleAnalysis.hoistable_imports/1` selects `from <stdlib> import
  # <name>` cases where the binding is a pure function — emit those as
  # module-top `defp`s so top-level user `def`s can call them without
  # being demoted into py_main lambdas. Each clause below mirrors the
  # runtime lambda shape that the corresponding `Stdlib.<Mod>` import
  # path would otherwise emit at runtime; keeping them in sync is the
  # cost of avoiding closure-demotion for the common case.

  defp emit_hoisted_imports([], context), do: {[], context}

  defp emit_hoisted_imports(imports, context) do
    asts =
      Enum.map(imports, fn {alias_n, orig, mod, _arity} ->
        hoisted_defp(mod, orig, alias_n)
      end)

    # Pre-populate stdlib_aliases for hoisted imports so that call sites
    # inside FunctionDef bodies (converted before the corresponding
    # ImportFrom statement runs through the converter) can still see
    # `<alias> → {mod, name}` and route accordingly. The duplicate
    # registration inside the ImportFrom path is a no-op.
    context =
      Enum.reduce(imports, context, fn {alias_n, orig, mod, _arity}, ctx ->
        %{ctx | stdlib_aliases: Map.put(ctx.stdlib_aliases, alias_n, {mod, orig})}
      end)

    {asts, context}
  end

  defp hoisted_defp("functools", "reduce", alias_n) do
    name = alias_n |> Naming.rewrite() |> String.to_atom()

    body =
      {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [],
       [
         {:iter, [], nil},
         {:init, [], nil},
         {:fn, [],
          [
            {:->, [],
             [
               [{:x, [], nil}, {:acc, [], nil}],
               {{:., [], [{:fn_arg, [], nil}]}, [], [{:acc, [], nil}, {:x, [], nil}]}
             ]}
          ]}
       ]}

    {:defp, [],
     [
       {name, [], [{:fn_arg, [], nil}, {:iter, [], nil}, {:init, [], nil}]},
       [do: body]
     ]}
  end

  defp hoisted_defp("itertools", "repeat", alias_n) do
    name = alias_n |> Naming.rewrite() |> String.to_atom()

    body =
      {{:., [], [{:__aliases__, [], [:List]}, :duplicate]}, [],
       [{:elem, [], nil}, {:times, [], nil}]}

    {:defp, [],
     [
       {name, [], [{:elem, [], nil}, {:times, [], nil}]},
       [do: body]
     ]}
  end

  defp hoisted_defp("itertools", "chain", alias_n) do
    name = alias_n |> Naming.rewrite() |> String.to_atom()
    body = {:py_itertools_chain, [], [{:iters, [], nil}]}

    {:defp, [], [{name, [], [{:iters, [], nil}]}, [do: body]]}
  end

  defp hoisted_defp("itertools", "accumulate", alias_n) do
    name = alias_n |> Naming.rewrite() |> String.to_atom()
    body = {:py_itertools_accumulate, [], [{:iter, [], nil}]}

    {:defp, [], [{name, [], [{:iter, [], nil}]}, [do: body]]}
  end

  defp hoisted_defp("itertools", "groupby", alias_n) do
    name = alias_n |> Naming.rewrite() |> String.to_atom()
    body = {:py_itertools_groupby, [], [{:iter, [], nil}]}

    {:defp, [], [{name, [], [{:iter, [], nil}]}, [do: body]]}
  end

  # --- If/IfExp helpers --------------------------------------------------

  defp convert_ifexp_runtime(test, body, orelse, context) do
    # M1 — type-narrow the body arm when `test` is an `isinstance(x, T)`
    # call. Save/restore types so the orelse arm doesn't see the body's
    # narrowing.
    saved_types = context.types
    body_context = TypeInfer.IsinstanceNarrowing.narrow(test, context)

    {test_ast, body_context} = convert_test(test, body_context)
    {body_ast, body_context} = convert(body, body_context)

    context = %{body_context | types: saved_types}
    {orelse_ast, context} = convert(orelse, context)

    {{:if, [], [test_ast, [do: body_ast, else: orelse_ast]]}, context}
  end

  defp convert_if_runtime(test, body, orelse, context) do
    # PR 11 — branch-isolated types. Type bindings introduced inside an
    # If body / orelse leak into the surrounding scope as `:any` (the
    # lub of "set in this branch" + "untouched in the other" is the
    # safe conservative type since we don't know which branch ran).
    # We snapshot before conversion, let the inner conversions update
    # types as they go (so within-branch specialization fires), and
    # restore on exit. Names typed *before* the If keep their type.
    saved_types = context.types

    # PR 12 — isinstance narrowing for the body-only case. Detect
    # `if isinstance(x, T):` and prime `ctx.types[x]` to `T`'s lattice
    # type before body conversion. emit_else's per-branch isolation is
    # left to future work (the body and orelse share a `convert_test`
    # call site so narrowing one without affecting the other is more
    # intrusive than current scope permits).
    body_context =
      case orelse do
        [] -> TypeInfer.IsinstanceNarrowing.narrow(test, context)
        _ -> context
      end

    {ast, context} =
      case orelse do
        [] -> Nodes.If.emit_only(test, body, body_context)
        [%{"_type" => "If"} = _elif | _] -> Nodes.If.emit_cond_chain(test, body, orelse, context)
        _ -> Nodes.If.emit_else(test, body, orelse, context)
      end

    {ast, %{context | types: saved_types}}
  end

  defp convert_body_inline([], context), do: {nil, context}

  defp convert_body_inline(stmts, context) when is_list(stmts) do
    {asts, context} = convert_each(stmts, context)
    {body_to_block(asts), context}
  end

  # Detect a test that folds to a known boolean at convert time.
  # Two shapes:
  #   * Single-op `Compare(Eq|NotEq)` whose operands both fold via
  #     `LiteralFold.fold/1` (with `__name__` special-cased to
  #     "__main__" to match Pylixir's Name clause).
  #   * `Call(isinstance, [Name(n), type_ref])` where `n`'s lattice
  #     type in `context.types` matches the spec. Disjoint types are
  #     conservatively reported as `:unknown` — only positive matches
  #     fold to `{:ok, true}`. The orelse-elision case (`{:ok, false}`)
  #     stays out of scope until call-graph-driven monomorphization
  #     lands.
  defp const_fold_if_test(
         %{
           "_type" => "Compare",
           "left" => left,
           "ops" => [%{"_type" => op_type}],
           "comparators" => [right]
         },
         _context
       )
       when op_type in ["Eq", "NotEq"] do
    with {:ok, lv} <- fold_value(left),
         {:ok, rv} <- fold_value(right) do
      eq = lv == rv
      {:ok, if(op_type == "Eq", do: eq, else: not eq)}
    else
      _ -> :unknown
    end
  end

  defp const_fold_if_test(
         %{
           "_type" => "Call",
           "func" => %{"_type" => "Name", "id" => "isinstance"},
           "args" => [%{"_type" => "Name", "id" => name}, type_ref]
         },
         context
       ) do
    case Map.get(context.types, name, :any) do
      :any -> :unknown
      type -> if isinstance_type_match?(type, type_ref), do: {:ok, true}, else: :unknown
    end
  end

  defp const_fold_if_test(_, _), do: :unknown

  # True iff a value of lattice type `t` provably matches the Python
  # `isinstance` spec `type_ref`. Conservative — returns false for any
  # shape we don't explicitly recognize, including unions and `:any`.
  defp isinstance_type_match?(t, %{"_type" => "Name", "id" => "int"})
       when t == {:int} or t == {:int_lit_nonneg} or t == {:bool},
       do: true

  defp isinstance_type_match?({:float}, %{"_type" => "Name", "id" => "float"}), do: true
  defp isinstance_type_match?({:str}, %{"_type" => "Name", "id" => "str"}), do: true
  defp isinstance_type_match?({:bool}, %{"_type" => "Name", "id" => "bool"}), do: true
  defp isinstance_type_match?({:list, _}, %{"_type" => "Name", "id" => "list"}), do: true
  defp isinstance_type_match?({:tuple, _}, %{"_type" => "Name", "id" => "tuple"}), do: true
  defp isinstance_type_match?({:dict, _, _}, %{"_type" => "Name", "id" => "dict"}), do: true
  defp isinstance_type_match?({:set}, %{"_type" => "Name", "id" => "set"}), do: true

  defp isinstance_type_match?({:none}, %{"_type" => "Constant", "value" => nil}), do: true

  defp isinstance_type_match?(_, _), do: false

  defp fold_value(%{"_type" => "Name", "id" => "__name__"}), do: {:ok, "__main__"}
  defp fold_value(node), do: Pylixir.LiteralFold.fold(node)

  # --- Expr-clause helpers (statement-form mutations & class calls) ------
  #
  # All the helpers that drive the `Expr` clause's nested-case routing
  # live below the catch-all `convert/2`. Keeping them out of the
  # `def convert` cluster avoids the "clauses with the same name and
  # arity should be grouped" compile-time warning.

  defp emit_bisect_insort_rebind(list_name, method, args, context) do
    {arg_asts, context} = convert_each(args, context)
    list_atom = list_name |> Naming.rewrite() |> String.to_atom()
    list_ref = {list_atom, [], nil}

    helper =
      case method do
        "insort_left" -> :py_bisect_insort_left
        _ -> :py_bisect_insort_right
      end

    call = {helper, [], [list_ref | arg_asts]}
    context = bind_name(context, list_name)
    {{:=, [], [list_ref, call]}, context}
  end

  defp convert_expr_continue(value, context) do
    case detect_mutating_class_method_call(value, context) do
      {:ok, obj_name, class_name, method, args} ->
        # `obj.method(args)` as a STATEMENT on a mutating method:
        # the method returns updated self, so rebind obj. Without
        # this, the mutation (a Map.put on a fresh map) would be
        # discarded as the Expr's value.
        emit_class_method_rebind(obj_name, class_name, method, args, context)

      :no_subscript_receiver ->
        # `dsu[t].method(args)` style — receiver is a Subscript,
        # so we can't rebind the obj slot. Emit `_ = call` to
        # silence Elixir's "result is ignored" warning; the
        # mutation is lost (Pylixir's first-pass class lowering
        # doesn't model "rebind into a subscript slot"). The
        # call still runs for any side effects.
        convert_discarded_mutating_call(value, context)

      :no ->
        case Nodes.Mutations.detect(value) do
          :none ->
            convert(value, context)

          {:name, target_name, method, args, kwargs, source_node} ->
            Nodes.Mutations.emit(target_name, method, args, kwargs, source_node, context)

          {:subscript, coll_name, slice, method, args, kwargs, source_node} ->
            Nodes.Mutations.emit_subscript(
              coll_name,
              slice,
              method,
              args,
              kwargs,
              source_node,
              context
            )

          {:subscript2, coll_name, slice_outer, slice_inner, method, args, kwargs, source_node} ->
            Nodes.Mutations.emit_subscript2(
              coll_name,
              slice_outer,
              slice_inner,
              method,
              args,
              kwargs,
              source_node,
              context
            )

          {:obj_attr_subscript, obj_name, attr_name, slice, method, args, kwargs, source_node} ->
            Nodes.Mutations.emit_obj_attr_subscript(
              obj_name,
              attr_name,
              slice,
              method,
              args,
              kwargs,
              source_node,
              context
            )
        end
    end
  end

  # Recognise `obj.<method>(args)` where `method` is a known mutating
  # class method. Returns `{:ok, obj_name, class_name, method, args}`
  # when obj is a bare Name (we rebind it), `:no_subscript_receiver`
  # when obj is a Subscript (caller wraps with `_ = ...` to discard
  # cleanly; mutation is lost), or `:no` otherwise.
  defp detect_mutating_class_method_call(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => obj_name},
             "attr" => method
           },
           "args" => args,
           "keywords" => []
         },
         context
       ) do
    case Map.get(context.class_methods, method, []) do
      [{class_name, :mutating}] -> {:ok, obj_name, class_name, method, args}
      _ -> :no
    end
  end

  defp detect_mutating_class_method_call(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Subscript"},
             "attr" => method
           }
         },
         context
       ) do
    case Map.get(context.class_methods, method, []) do
      [{_class_name, :mutating}] -> :no_subscript_receiver
      _ -> :no
    end
  end

  defp detect_mutating_class_method_call(_, _), do: :no

  defp convert_discarded_mutating_call(value, context) do
    {call_ast, context} = convert(value, context)
    {{:=, [], [{:_, [], nil}, call_ast]}, context}
  end

  defp emit_class_method_rebind(obj_name, class_name, method, args, context) do
    {arg_asts, context} = convert_each(args, context)
    fn_name = method_fn_name(class_name, method)
    obj_atom = obj_name |> Naming.rewrite() |> String.to_atom()
    obj_ref = {obj_atom, [], nil}
    call = {fn_name, [], [obj_ref | arg_asts]}
    context = bind_name(context, obj_name)
    # Mutating methods return `{return_value, updated_self}`; the
    # statement-form caller discards the value and rebinds obj only.
    pattern = {{:_, [], nil}, obj_ref}
    {{:=, [], [pattern, call]}, context}
  end

  # --- `try` binding-threading helpers -----------------------------------
  #
  # Together these make names first-assigned inside a Python `try` body
  # visible after the Elixir `try ... end` expression. See the Try
  # `convert/2` clause above for the full lowering and the rescue-side
  # nil-prebind rationale.

  defp name_atom_ref(name) do
    atom = name |> Naming.rewrite() |> String.to_atom()
    {atom, [], nil}
  end

  # Append `{tail_value, var1, var2, ...}` to a block expression so the
  # surrounding `try`/`rescue` clause's result carries the bindings.
  defp append_binding_tuple(block, []), do: block

  defp append_binding_tuple(block, names) do
    refs = Enum.map(names, &name_atom_ref/1)
    body_to_block([block, tuple_pattern([block_tail_marker() | refs])])
  end

  defp block_tail_marker, do: nil

  # Prepend `name = nil` for each name to a block. Used in `try`'s
  # rescue clause so the appended binding tuple always references
  # in-scope variables; see the call site for the full reasoning.
  defp prepend_nil_bindings(block, []), do: block

  defp prepend_nil_bindings(block, names) do
    nil_binds = Enum.map(names, fn n -> {:=, [], [name_atom_ref(n), nil]} end)
    body_to_block(nil_binds ++ [block])
  end

  # --- heapq statement-mutation rebind emitter ---------------------------
  #
  # Recognition lives on `Pylixir.Stdlib.Heapq.statement_mutation_call/2`
  # (used by Converter / ModuleAnalysis / LoopAnalysis). This emitter
  # owns the rebind shape: `heap = py_heappush(heap, item)` etc.

  defp emit_heapq_statement_rebind(heap_name, "heappush", [item_node], context) do
    {item_ast, context} = convert(item_node, context)
    heap_atom = heap_name |> Naming.rewrite() |> String.to_atom()
    heap_ref = {heap_atom, [], nil}
    context = bind_name(context, heap_name)
    {{:=, [], [heap_ref, {:py_heappush, [], [heap_ref, item_ast]}]}, context}
  end

  defp emit_heapq_statement_rebind(heap_name, "heapify", [], context) do
    heap_atom = heap_name |> Naming.rewrite() |> String.to_atom()
    heap_ref = {heap_atom, [], nil}
    context = bind_name(context, heap_name)
    {{:=, [], [heap_ref, {:py_heapify, [], [heap_ref]}]}, context}
  end

  # Emit `raise(RuntimeError, "<ClassName>: <msg>")`. The msg is the
  # first arg (Python convention: `raise ValueError("nope")`). With
  # no args we just stringify the class name. Pylixir doesn't model
  # exception classes, so everything funnels through RuntimeError —
  # callers can still `try/except:` since the existing except is
  # type-agnostic (rescues any).
  defp emit_raise(cls_name, [], context) do
    {{:raise, [], [{:__aliases__, [], [:RuntimeError]}, cls_name]}, context}
  end

  defp emit_raise(cls_name, [msg_node | _], context) do
    {msg_ast, context} = convert(msg_node, context)
    formatted = {:<>, [], [cls_name <> ": ", {:py_str, [], [msg_ast]}]}
    {{:raise, [], [{:__aliases__, [], [:RuntimeError]}, formatted]}, context}
  end

  # --- Operator emission -------------------------------------------------

  defp unary_op_ast(%{"_type" => "UAdd"}, operand_ast, _node), do: operand_ast

  # Constant-fold `-<float-literal>` to the negated literal so IEEE-754
  # negative-zero survives. `py_sub(0, 0.0)` would yield `0.0` (a
  # positive zero) — losing the sign and producing `print(-0.0)` →
  # `"0.0"` instead of Python's `"-0.0"`. Same fold for integer
  # literals so trivial expressions stay readable.
  defp unary_op_ast(%{"_type" => "USub"}, operand_ast, _node) when is_float(operand_ast),
    do: -operand_ast

  defp unary_op_ast(%{"_type" => "USub"}, operand_ast, _node) when is_integer(operand_ast),
    do: -operand_ast

  defp unary_op_ast(%{"_type" => "USub"}, operand_ast, _node), do: {:py_sub, [], [0, operand_ast]}

  defp unary_op_ast(%{"_type" => "Invert"}, operand_ast, _node) do
    {{:., [], [{:__aliases__, [], [:Bitwise]}, :bnot]}, [], [operand_ast]}
  end

  defp unary_op_ast(%{"_type" => "Not"}, operand_ast, _node) do
    {:!, [], [{:truthy?, [], [operand_ast]}]}
  end

  # Type-aware emit for `not <expr>` — see `unary_op_not/3` below. Kept
  # as a separate dispatch path because the type-aware version needs
  # the original operand node + context (to infer type) while the
  # ast-only `unary_op_ast/3` clauses receive only the converted AST.

  defp unary_op_ast(%{"_type" => other}, _operand_ast, node) do
    raise UnsupportedNodeError,
      node_type: other,
      hint: "unary operator `#{other}` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # `bin_op_ast/4` is the legacy entry point (AugAssign callers still
  # use it). It dispatches to `/6` with `:any` operand types — no
  # specialization, identical emit to before. New callers (the BinOp
  # clause) compute types via `TypeInfer.infer_expr/2` and call `/6`
  # directly so specializations can fire.
  defp bin_op_ast(op, l, r, node), do: bin_op_ast(op, l, r, node, :any, :any)

  # Add/Sub/Mult/Div: type-aware specialization (decision Q2-B for
  # `Mult` on str/list × {:int_lit_nonneg}). Bool-tainted operands
  # (hazard #9 / decision Q7-A) inhibit specialization — `True + 1 = 2`
  # in Python but `true + 1` raises in Elixir. `TypeInfer.bin_op_type/3`
  # already returns `:any` when bool is involved, but we re-check at
  # the emit site so direct callers can't bypass it.

  defp bin_op_ast(%{"_type" => "Add"}, l, r, _node, lt, rt) do
    cond do
      bool_tainted_pair?(lt, rt) -> {:py_add, [], [l, r]}
      TypeInfer.is_int?(lt) and TypeInfer.is_int?(rt) -> {:+, [], [l, r]}
      TypeInfer.is_str?(lt) and TypeInfer.is_str?(rt) -> {:<>, [], [l, r]}
      TypeInfer.is_list?(lt) and TypeInfer.is_list?(rt) -> {:++, [], [l, r]}
      true -> {:py_add, [], [l, r]}
    end
  end

  defp bin_op_ast(%{"_type" => "Sub"}, l, r, _node, lt, rt) do
    cond do
      bool_tainted_pair?(lt, rt) -> {:py_sub, [], [l, r]}
      TypeInfer.is_int?(lt) and TypeInfer.is_int?(rt) -> {:-, [], [l, r]}
      true -> {:py_sub, [], [l, r]}
    end
  end

  defp bin_op_ast(%{"_type" => "Mult"}, l, r, _node, lt, rt) do
    cond do
      bool_tainted_pair?(lt, rt) ->
        {:py_mult, [], [l, r]}

      TypeInfer.is_int?(lt) and TypeInfer.is_int?(rt) ->
        {:*, [], [l, r]}

      # `"abc" * n` — Python returns "" for n <= 0; String.duplicate
      # crashes on negative. Only the literal-nonneg int refinement
      # makes the specialization safe (decision Q2-B). Dynamic ints fall
      # through to py_mult, which has the `b <= 0` clause.
      TypeInfer.is_str?(lt) and rt == {:int_lit_nonneg} ->
        string_duplicate(l, r)

      lt == {:int_lit_nonneg} and TypeInfer.is_str?(rt) ->
        string_duplicate(r, l)

      TypeInfer.is_list?(lt) and rt == {:int_lit_nonneg} ->
        list_duplicate_concat(l, r)

      lt == {:int_lit_nonneg} and TypeInfer.is_list?(rt) ->
        list_duplicate_concat(r, l)

      true ->
        {:py_mult, [], [l, r]}
    end
  end

  # Python 3 `/` is true division: int/int = float. Elixir `Kernel./`
  # has matching semantics for two numerics, so emit directly when both
  # sides are statically numeric. Bool-tainted falls through.
  defp bin_op_ast(%{"_type" => "Div"}, l, r, _node, lt, rt) do
    cond do
      bool_tainted_pair?(lt, rt) -> {:py_div, [], [l, r]}
      numeric_type?(lt) and numeric_type?(rt) -> {:/, [], [l, r]}
      true -> {:py_div, [], [l, r]}
    end
  end

  # `int ** nonneg-int-literal` → `Integer.pow/2`. Python's `**` with
  # an integer base returns int for nonneg exponents and a float for
  # negative ones — we can't pick Integer.pow at compile time without
  # proving the exponent is nonneg, hence the `{:int_lit_nonneg}`
  # gate (same `Q2-B` shape Mult uses for `"abc" * 3`). Dynamic
  # int exponents fall through to `py_pow`'s runtime guard which
  # picks `:math.pow` for negatives.
  defp bin_op_ast(%{"_type" => "Pow"}, l, r, _node, lt, rt) do
    cond do
      bool_tainted_pair?(lt, rt) ->
        {:py_pow, [], [l, r]}

      TypeInfer.is_int?(lt) and rt == {:int_lit_nonneg} ->
        {{:., [], [{:__aliases__, [], [:Integer]}, :pow]}, [], [l, r]}

      true ->
        {:py_pow, [], [l, r]}
    end
  end

  defp bin_op_ast(%{"_type" => "FloorDiv"}, l, r, _node, lt, rt) do
    cond do
      bool_tainted_pair?(lt, rt) ->
        {:py_floor_div, [], [l, r]}

      TypeInfer.is_int?(lt) and TypeInfer.is_int?(rt) ->
        {{:., [], [{:__aliases__, [], [:Integer]}, :floor_div]}, [], [l, r]}

      true ->
        {:py_floor_div, [], [l, r]}
    end
  end

  # `int % int` → `Integer.mod/2`. Specialization avoids pulling in
  # `py_mod`'s polymorphic clauses, which include a `is_binary(a)`
  # branch that drags the *entire* percent-format machinery
  # (`py_str_percent_format`, `parse_percent_*`, `format_percent_*`,
  # which in turn pull `py_str` + `py_repr`). One unspecialised `i %
  # 15` against an obviously-int operand was therefore enough to
  # inflate a 9-line fizzbuzz to a ~320-line emit. Bool-tainted falls
  # through because `True % 2` is `1` in Python but `true % 2` raises
  # in Elixir.
  defp bin_op_ast(%{"_type" => "Mod"}, l, r, _node, lt, rt) do
    cond do
      bool_tainted_pair?(lt, rt) ->
        {:py_mod, [], [l, r]}

      TypeInfer.is_int?(lt) and TypeInfer.is_int?(rt) ->
        {{:., [], [{:__aliases__, [], [:Integer]}, :mod]}, [], [l, r]}

      true ->
        {:py_mod, [], [l, r]}
    end
  end

  defp bin_op_ast(%{"_type" => "LShift"}, l, r, _node, _lt, _rt), do: bitwise_call(:bsl, l, r)
  defp bin_op_ast(%{"_type" => "RShift"}, l, r, _node, _lt, _rt), do: bitwise_call(:bsr, l, r)
  # Python's `|` / `&` / `^` are overloaded: bitwise on ints, set ops
  # on MapSets. Route through `py_bor` / `py_band` / `py_bxor` helpers
  # which dispatch at runtime. (LShift/RShift stay direct — there's
  # no set equivalent.)
  defp bin_op_ast(%{"_type" => "BitOr"}, l, r, _node, _lt, _rt), do: {:py_bor, [], [l, r]}
  defp bin_op_ast(%{"_type" => "BitAnd"}, l, r, _node, _lt, _rt), do: {:py_band, [], [l, r]}
  defp bin_op_ast(%{"_type" => "BitXor"}, l, r, _node, _lt, _rt), do: {:py_bxor, [], [l, r]}

  defp bin_op_ast(%{"_type" => "MatMult"}, _l, _r, node, _lt, _rt) do
    raise UnsupportedNodeError,
      node_type: "MatMult",
      hint: "matrix-multiplication operator `@` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp bin_op_ast(%{"_type" => other}, _l, _r, node, _lt, _rt) do
    raise UnsupportedNodeError,
      node_type: other,
      hint: "binary operator `#{other}` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp bitwise_call(fun_name, l, r) do
    {{:., [], [{:__aliases__, [], [:Bitwise]}, fun_name]}, [], [l, r]}
  end

  # ---- bin_op specialization helpers ---------------------------------

  defp bool_tainted_pair?(lt, rt), do: bool_tainted?(lt) or bool_tainted?(rt)

  defp bool_tainted?({:bool}), do: true
  defp bool_tainted?({:union, set}), do: MapSet.member?(set, {:bool})
  defp bool_tainted?(_), do: false

  defp numeric_type?({:int}), do: true
  defp numeric_type?({:int_lit_nonneg}), do: true
  defp numeric_type?({:float}), do: true
  defp numeric_type?(_), do: false

  defp string_duplicate(s, n) do
    {{:., [], [{:__aliases__, [], [:String]}, :duplicate]}, [], [s, n]}
  end

  defp list_duplicate_concat(l, n) do
    duplicate = {{:., [], [{:__aliases__, [], [:List]}, :duplicate]}, [], [l, n]}
    {{:., [], [{:__aliases__, [], [:Enum]}, :concat]}, [], [duplicate]}
  end

  defp bool_op_atom(%{"_type" => "And"}, _node), do: :&&
  defp bool_op_atom(%{"_type" => "Or"}, _node), do: :||

  defp bool_op_atom(%{"_type" => other}, node) do
    raise UnsupportedNodeError,
      node_type: other,
      hint: "boolean operator `#{other}` is not supported",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # `a and b` → `case a do v -> if truthy?(v), do: b, else: v end`
  # `a or  b` → `case a do v -> if truthy?(v), do: v, else: b end`
  #
  # The `case` binding avoids double-evaluating `a` (its AST may have
  # side effects). `v` is scoped to the case clause so it can't shadow
  # caller-side bindings.
  defp py_short_circuit(:&&, acc_ast, next_ast) do
    v = {:py_bool_v, [], nil}
    body = {:if, [], [{:truthy?, [], [v]}, [do: next_ast, else: v]]}
    {:case, [], [acc_ast, [do: [{:->, [], [[v], body]}]]]}
  end

  defp py_short_circuit(:||, acc_ast, next_ast) do
    v = {:py_bool_v, [], nil}
    body = {:if, [], [{:truthy?, [], [v]}, [do: v, else: next_ast]]}
    {:case, [], [acc_ast, [do: [{:->, [], [[v], body]}]]]}
  end

  @doc false
  def bind_name(context, name) when is_binary(name) do
    [head | rest] = context.scopes
    %{context | scopes: [MapSet.put(head, name) | rest]}
  end

  # --- AugAssign dispatch -----------------------------------------------

  defp aug_assign(%{"_type" => "Name", "id" => id}, op, value, node, context) do
    cond do
      MapSet.member?(context.mutable_module_dicts, id) ->
        # `time += 1` on a module-level mutable var (Python `global
        # time`). Read+combine+write through process dict so the
        # mutation persists in any caller's view.
        {value_ast, context} = convert(value, context)
        old = MutableModuleDict.get_ast(id)
        combined = bin_op_ast(op, old, value_ast, node)
        {MutableModuleDict.put_ast(id, combined), context}

      true ->
        synthetic_binop = %{
          "_type" => "BinOp",
          "op" => op,
          "left" => %{"_type" => "Name", "id" => id},
          "right" => value
        }

        # T5 op-narrowing: pass the operand types so `bin_op_ast` can pick
        # the native op — `list += list` → `++`, `int += int` → `+`,
        # `str += str` → `<>` — instead of the polymorphic `py_add` the
        # typeless 4-arg form emits. Semantics-preserving (same surface
        # `bin_op_ast` already uses for typed `BinOp`).
        lt = TypeInfer.infer_expr(%{"_type" => "Name", "id" => id}, context)
        rt = TypeInfer.infer_expr(value, context)
        result_type = TypeInfer.infer_expr(synthetic_binop, context)
        {value_ast, context} = convert(value, context)
        context = TypeInfer.bind(context, id, result_type)
        context = bind_name(context, id)
        target_atom = id |> Naming.rewrite() |> String.to_atom()
        target_ref = {target_atom, [], nil}
        rhs = bin_op_ast(op, target_ref, value_ast, node, lt, rt)
        {{:=, [], [target_ref, rhs]}, context}
    end
  end

  # `<obj>.<outer>.<inner> += value` — depth-2 attribute AugAssign.
  # Reads `obj.outer.inner`, combines with `value`, writes back
  # through both map layers. Python's aliasing semantics aren't
  # modelled (Pylixir's instances are immutable maps), so for code
  # that relies on multiple references to `obj.outer` observing the
  # update via aliasing this will silently produce wrong results.
  # For non-aliased usage (the common case in single-owner data
  # structures) the result matches Python.
  defp aug_assign(
         %{
           "_type" => "Attribute",
           "value" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => obj_name},
             "attr" => outer_attr
           },
           "attr" => inner_attr
         },
         op,
         value,
         node,
         context
       ) do
    {value_ast, context} = convert(value, context)
    obj_atom = obj_name |> Naming.rewrite() |> String.to_atom()
    obj_ref = {obj_atom, [], nil}
    outer_atom = String.to_atom(outer_attr)
    inner_atom = String.to_atom(inner_attr)

    outer_read =
      {{:., [], [{:__aliases__, [], [:Map]}, :fetch!]}, [], [obj_ref, outer_atom]}

    inner_read =
      {{:., [], [{:__aliases__, [], [:Map]}, :fetch!]}, [], [outer_read, inner_atom]}

    combined = bin_op_ast(op, inner_read, value_ast, node)

    new_outer =
      {{:., [], [{:__aliases__, [], [:Map]}, :put]}, [], [outer_read, inner_atom, combined]}

    new_obj =
      {{:., [], [{:__aliases__, [], [:Map]}, :put]}, [], [obj_ref, outer_atom, new_outer]}

    context = bind_name(context, obj_name)
    {{:=, [], [obj_ref, new_obj]}, context}
  end

  # `<obj>.<attr> += value` — read+write an instance-map attribute.
  # Mirrors the Assign clause's general `obj.attr = ...` handling.
  defp aug_assign(
         %{
           "_type" => "Attribute",
           "value" => %{"_type" => "Name", "id" => obj_name},
           "attr" => attr
         },
         op,
         value,
         node,
         context
       ) do
    {value_ast, context} = convert(value, context)
    attr_atom = String.to_atom(attr)
    obj_atom = obj_name |> Naming.rewrite() |> String.to_atom()
    obj_ref = {obj_atom, [], nil}

    attr_read =
      {{:., [], [{:__aliases__, [], [:Map]}, :fetch!]}, [], [obj_ref, attr_atom]}

    combined = bin_op_ast(op, attr_read, value_ast, node)

    map_put =
      {{:., [], [{:__aliases__, [], [:Map]}, :put]}, [], [obj_ref, attr_atom, combined]}

    context = bind_name(context, obj_name)
    {{:=, [], [obj_ref, map_put]}, context}
  end

  # `<coll>[<slice>].<attr> += value` — AugAssign on an Attribute whose
  # receiver is a depth-1 Subscript on a Name. Common in network-flow /
  # adjacency-list code: `edges[i].cap -= flow`. Lowers by rebinding
  # the coll: `coll = py_setitem(coll, i, Map.put(py_getitem(coll, i),
  # :attr, Map.fetch!(py_getitem(coll, i), :attr) <op> value))`.
  # `slice` is temp-bound when non-trivial (it appears twice in the
  # output, once in `py_getitem`, once in `py_setitem`).
  defp aug_assign(
         %{
           "_type" => "Attribute",
           "value" => %{
             "_type" => "Subscript",
             "value" => %{"_type" => "Name", "id" => coll_name},
             "slice" => slice
           },
           "attr" => attr
         },
         op,
         value,
         node,
         context
       ) do
    {value_ast, context} = convert(value, context)
    {slice_ref, slice_binding, context} = maybe_temp_bind(slice, context)

    coll_atom = coll_name |> Naming.rewrite() |> String.to_atom()
    coll_ref = {coll_atom, [], nil}
    attr_atom = String.to_atom(attr)

    elem_get = {:py_getitem, [], [coll_ref, slice_ref]}

    attr_read =
      {{:., [], [{:__aliases__, [], [:Map]}, :fetch!]}, [], [elem_get, attr_atom]}

    combined = bin_op_ast(op, attr_read, value_ast, node)

    new_elem =
      {{:., [], [{:__aliases__, [], [:Map]}, :put]}, [], [elem_get, attr_atom, combined]}

    setitem = {:py_setitem, [], [coll_ref, slice_ref, new_elem]}
    assign = {:=, [], [coll_ref, setitem]}

    context = TypeInfer.demote(context, coll_name)
    context = bind_name(context, coll_name)

    ast =
      case slice_binding do
        nil -> assign
        b -> {:__block__, [], [b, assign]}
      end

    {ast, context}
  end

  # `<obj>.<attr>[<slice>] += value` — common FenwickTree / SegmentTree
  # shape, generalised to any object root. Must precede the generic
  # Subscript clause so it actually matches.
  defp aug_assign(
         %{
           "_type" => "Subscript",
           "value" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => obj_name},
             "attr" => attr
           },
           "slice" => slice
         },
         op,
         value,
         node,
         context
       ) do
    {slice_ast, context} = convert(slice, context)
    {value_ast, context} = convert(value, context)
    attr_atom = String.to_atom(attr)
    obj_atom = obj_name |> Naming.rewrite() |> String.to_atom()
    obj_ref = {obj_atom, [], nil}

    attr_read =
      {{:., [], [{:__aliases__, [], [:Map]}, :fetch!]}, [], [obj_ref, attr_atom]}

    getitem = {:py_getitem, [], [attr_read, slice_ast]}
    combined = bin_op_ast(op, getitem, value_ast, node)
    setitem = {:py_setitem, [], [attr_read, slice_ast, combined]}

    map_put =
      {{:., [], [{:__aliases__, [], [:Map]}, :put]}, [], [obj_ref, attr_atom, setitem]}

    context = bind_name(context, obj_name)
    {{:=, [], [obj_ref, map_put]}, context}
  end

  # Nested-subscript AugAssign: `m[a][b]... += v` where the chain
  # bottoms out at a bare Name. The general clause below only rebinds
  # when `collection` is a Name; a nested chain would otherwise emit a
  # `py_setitem` whose result is discarded (the outer name never sees
  # the update). Rebind the root through nested py_setitem, reading the
  # current value via the matching py_getitem chain. Slices are
  # temp-bound so they evaluate once (RFC single-eval). Mirrors the
  # plain-Assign nested rebind in `Pylixir.Nodes.Assign`.
  defp aug_assign(
         %{"_type" => "Subscript", "value" => %{"_type" => "Subscript"}} = target,
         op,
         value,
         node,
         context
       ) do
    case aug_nested_subscript_chain(target, []) do
      {:ok, coll_id, slices} ->
        {value_ast, context} = convert(value, context)
        {coll_ast, context} = convert(%{"_type" => "Name", "id" => coll_id}, context)

        {slice_refs, bindings, context} =
          Enum.reduce(slices, {[], [], context}, fn slice_node, {refs, binds, ctx} ->
            {ref, binding, ctx} = maybe_temp_bind(slice_node, ctx)
            binds = if binding, do: [binding | binds], else: binds
            {[ref | refs], binds, ctx}
          end)

        slice_refs = Enum.reverse(slice_refs)
        bindings = Enum.reverse(bindings)

        read = Enum.reduce(slice_refs, coll_ast, fn s, acc -> {:py_getitem, [], [acc, s]} end)
        combined = bin_op_ast(op, read, value_ast, node)
        new_value = build_nested_setitem(coll_ast, slice_refs, combined)
        context = bind_name(context, coll_id)
        assign = {:=, [], [coll_ast, new_value]}

        result =
          case bindings do
            [] -> assign
            _ -> {:__block__, [], bindings ++ [assign]}
          end

        {result, context}

      :error ->
        raise UnsupportedNodeError,
          node_type: "AugAssign",
          hint:
            "Nested-subscript AugAssign `<#{Map.get(target, "_type")}>[…][…] <op>= v` is only supported for chains rooted at a bare Name",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  defp aug_assign(
         %{"_type" => "Subscript", "value" => collection, "slice" => slice},
         op,
         value,
         node,
         context
       ) do
    {coll_ast, coll_binding, context} = maybe_temp_bind(collection, context)
    {slice_ast, slice_binding, context} = maybe_temp_bind(slice, context)
    {value_ast, context} = convert(value, context)

    getitem = {:py_getitem, [], [coll_ast, slice_ast]}
    combined = bin_op_ast(op, getitem, value_ast, node)
    setitem = {:py_setitem, [], [coll_ast, slice_ast, combined]}

    final =
      case collection do
        %{"_type" => "Name", "id" => coll_id} ->
          bind_name_returning_assign(context, coll_id, coll_ast, setitem)

        _ ->
          {setitem, context}
      end

    {final_ast, context} = final
    bindings = Enum.reject([coll_binding, slice_binding], &is_nil/1)

    result =
      case bindings do
        [] -> final_ast
        _ -> {:__block__, [], bindings ++ [final_ast]}
      end

    {result, context}
  end

  defp aug_assign(target, _op, _value, node, _context) do
    raise UnsupportedNodeError,
      node_type: "AugAssign",
      hint:
        "AugAssign target shape `#{Map.get(target, "_type")}` is not supported (use a Name or Subscript target)",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp bind_name_returning_assign(context, coll_id, coll_ref, setitem) do
    context = bind_name(context, coll_id)
    {{:=, [], [coll_ref, setitem]}, context}
  end

  # Walk a (possibly nested) Subscript chain, collecting slices
  # outermost-first. Succeeds only when the chain bottoms out at a bare
  # Name (its rebind target).
  defp aug_nested_subscript_chain(%{"_type" => "Subscript", "value" => v, "slice" => s}, acc) do
    case v do
      %{"_type" => "Name", "id" => id} -> {:ok, id, [s | acc]}
      %{"_type" => "Subscript"} = inner -> aug_nested_subscript_chain(inner, [s | acc])
      _ -> :error
    end
  end

  # `m[a][b] = v` ↦ `py_setitem(m, a, py_setitem(py_getitem(m, a), b, v))`.
  defp build_nested_setitem(coll_ast, [last_slice], value_ast) do
    {:py_setitem, [], [coll_ast, last_slice, value_ast]}
  end

  defp build_nested_setitem(coll_ast, [s | rest], value_ast) do
    inner_get = {:py_getitem, [], [coll_ast, s]}
    inner_set = build_nested_setitem(inner_get, rest, value_ast)
    {:py_setitem, [], [coll_ast, s, inner_set]}
  end

  @doc false
  def var_bound?(context, var) do
    Enum.any?(context.scopes, &MapSet.member?(&1, var))
  end

  # `name_in_scope?` is a synonym kept for readability at the Call-router
  # site (where "name" is the natural term) — they walk the same scopes.
  @doc false
  def name_in_scope?(context, name) do
    Enum.any?(context.scopes, &MapSet.member?(&1, name))
  end

  # --- Call routing (T28) ------------------------------------------------

  # `isinstance(x, T)` consumes T by inspecting the bare-Name shape
  # (`Builtins.isinstance_call/2`). Routing T through the general Name
  # converter would now lower it to a unary builtin capture
  # (e.g. `fn x -> py_int(x) end`), which isinstance can't pattern-match
  # on. Pull T directly out of the Python AST instead. Builtins.emit
  # itself returns `{:error, hint}` for non-bare-Name second args, which
  # `Lowering.dispatch/4` surfaces with the existing hint.
  defp emit_name_call("isinstance", node, context) do
    args = Map.get(node, "args", [])
    {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)

    {emit_args, context} =
      case args do
        [x_node, %{"_type" => "Name", "id" => type_id}] ->
          {x_ast, context} = convert(x_node, context)
          {[x_ast, {String.to_atom(type_id), [], nil}], context}

        _ ->
          convert_each(args, context)
      end

    Lowering.dispatch(
      Builtins.emit("isinstance", emit_args, kwargs),
      "`isinstance/#{length(emit_args)}` is not a supported Python builtin call shape",
      node,
      context
    )
  end

  defp emit_name_call(id, node, context) do
    raw_args = Map.get(node, "args", [])

    cond do
      # N2 — `reduce(lambda, iter, init)` from `functools.reduce`
      # inlines at the call site as `Enum.reduce(iter, init, λ_flipped)`,
      # avoiding the hoisted wrapper. Only fires when the first arg is
      # a Lambda literal — swapping its params is local. Other shapes
      # (Name/Capture) fall through to the wrapper path.
      reduce_lambda_inline_target?(id, raw_args, context) ->
        emit_reduce_lambda_inline(raw_args, node, context)

      match?({:ok, _}, single_starred_args(raw_args)) ->
        {:ok, star_node} = single_starred_args(raw_args)
        emit_starred_call(id, star_node, node, context)

      true ->
        arg_types = Enum.map(raw_args, &TypeInfer.infer_expr(&1, context))
        {arg_asts, context} = convert_each(raw_args, context)
        {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)

        cond do
          # `Foo(args)` where `Foo` is a registered class — route to
          # the `Foo__init__/N` constructor `defp` emitted by
          # `convert_class_defs/2`. Returns the instance map.
          MapSet.member?(context.class_names, id) ->
            no_kwargs!(kwargs, id, node)
            fn_name = init_fn_name(id)
            {{fn_name, [], arg_asts}, context}

          # `from <mod> import <name>` was lowered to a capture of a
          # fixed arity. If the user calls it with a different arity,
          # bypass the in-scope lambda and dispatch through the stdlib
          # — that callback knows all arities the helper supports.
          Map.has_key?(context.stdlib_aliases, id) ->
            {mod, name} = context.stdlib_aliases[id]
            impl = Stdlib.impl(mod)

            Lowering.dispatch(
              impl.call([name], arg_asts, kwargs, node),
              "`#{id}/#{length(arg_asts)}` (alias for #{mod}.#{name}) is not a supported call shape",
              node,
              context
            )

          id == context.recursive_self_binding ->
            no_kwargs!(kwargs, id, node)
            self_ref = {:self, [], nil}
            {{{:., [], [self_ref]}, [], arg_asts ++ [self_ref]}, context}

          MapSet.member?(context.recursive_lambdas, id) ->
            no_kwargs!(kwargs, id, node)
            atom = id |> Naming.rewrite() |> String.to_atom()
            ref = {atom, [], nil}
            {{{:., [], [ref]}, [], arg_asts ++ [ref]}, context}

          name_in_scope?(context, id) ->
            no_kwargs!(kwargs, id, node)
            atom = id |> Naming.rewrite() |> String.to_atom()
            ref = {atom, [], nil}
            {{{:., [], [ref]}, [], arg_asts}, context}

          # User `def name` shadows a Python builtin (`def len(xs): …`,
          # `def next(seq, d): …`). Python's local-by-default name
          # resolution means the user's function takes precedence;
          # without this check, the builtin lowering would steal the
          # call site. Place BEFORE `Builtins.supported?` for that
          # reason. Hoisted-import names land in `known_functions` too,
          # so a `from itertools import reduce` alias also wins.
          MapSet.member?(context.known_functions, id) and
              not MapSet.member?(context.demoted_functions, id) ->
            no_kwargs!(kwargs, id, node)
            atom = id |> Naming.rewrite() |> String.to_atom()
            {{atom, [], arg_asts}, context}

          Builtins.supported?(id) ->
            Lowering.dispatch(
              Builtins.emit(id, arg_asts, kwargs, arg_types),
              "`#{id}/#{length(arg_asts)}` is not a supported Python builtin call shape",
              node,
              context
            )

          hint = Builtins.unsupported_hint(id) ->
            # Known Python builtin we deliberately don't lower (iter,
            # next, eval, ...) — fail loudly at transpile time instead
            # of emitting a bare call that breaks compilation later.
            # Skip when the user has shadowed the builtin with their
            # own top-level `def` of the same name; that resolves to
            # the user's function via the bare-call fallthrough.
            if MapSet.member?(context.known_functions, id) do
              no_kwargs!(kwargs, id, node)
              atom = id |> Naming.rewrite() |> String.to_atom()
              {{atom, [], arg_asts}, context}
            else
              raise UnsupportedNodeError,
                node_type: "Call",
                hint: hint,
                lineno: Map.get(node, "lineno"),
                col_offset: Map.get(node, "col_offset")
            end

          MapSet.member?(context.demoted_functions, id) ->
            # `id` is a top-level def that ModuleAnalysis demoted to a
            # closure (it transitively closes over a mutable module
            # binding). The closure binding gets emitted as
            # `id = fn ... end` inside py_main. Bare `id(args)` would
            # resolve to a never-emitted top-level defp; lower to
            # `id.(args)` so the lambda is invoked instead.
            no_kwargs!(kwargs, id, node)
            atom = id |> Naming.rewrite() |> String.to_atom()
            ref = {atom, [], nil}
            {{{:., [], [ref]}, [], arg_asts}, context}

          true ->
            no_kwargs!(kwargs, id, node)
            atom = id |> Naming.rewrite() |> String.to_atom()
            {{atom, [], arg_asts}, context}
        end
    end
  end

  # Recognise the common `f(*args)` shape — a single Starred argument
  # and nothing else. Mixed star + positional (`f(a, *xs, b)`) and
  # multiple stars require list-concat at the call site; not handled.
  defp single_starred_args([%{"_type" => "Starred", "value" => v}]), do: {:ok, v}
  defp single_starred_args(_), do: :no

  # N2 — recognize a `reduce(lambda, iter, init)` call that can inline
  # to `Enum.reduce(iter, init, fn elem, acc -> ... end)`. Only fires
  # when the function arg is a Python Lambda literal — swapping its
  # params (matching Python's `(acc, elem)` to Elixir's `(elem, acc)`)
  # is purely structural. Name/Capture/Attribute args fall through to
  # the existing hoisted-wrapper path.
  defp reduce_lambda_inline_target?("reduce", [%{"_type" => "Lambda"} | _] = args, context)
       when length(args) == 3 do
    case Map.get(context.stdlib_aliases, "reduce") do
      {"functools", "reduce"} -> true
      _ -> false
    end
  end

  defp reduce_lambda_inline_target?(_id, _args, _ctx), do: false

  defp emit_reduce_lambda_inline([lambda, iter_node, init_node], _node, context) do
    %{"args" => %{"args" => params}, "body" => body} = lambda

    case params do
      [acc_param, elem_param] ->
        {iter_ast, context} = convert(iter_node, context)
        {init_ast, context} = convert(init_node, context)

        # Param names are scoped to the lambda body — push onto scopes
        # so `convert(body)` resolves them as locals.
        acc_name = Map.get(acc_param, "arg")
        elem_name = Map.get(elem_param, "arg")
        acc_atom = acc_name |> Naming.rewrite() |> String.to_atom()
        elem_atom = elem_name |> Naming.rewrite() |> String.to_atom()

        saved_scopes = context.scopes
        [head | rest] = context.scopes
        scope_with_params = head |> MapSet.put(acc_name) |> MapSet.put(elem_name)
        context = %{context | scopes: [scope_with_params | rest]}

        {body_ast, context} = convert(body, context)
        context = %{context | scopes: saved_scopes}

        # `fn elem, acc -> body end` — params positionally swapped to
        # match Elixir's `Enum.reduce/3` callback signature. Body still
        # references the original Python names (`acc_atom`, `elem_atom`)
        # which now bind correctly via positional order.
        callback =
          {:fn, [],
           [
             {:->, [],
              [
                [{elem_atom, [], nil}, {acc_atom, [], nil}],
                body_ast
              ]}
           ]}

        reduce_call =
          {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [iter_ast, init_ast, callback]}

        {reduce_call, context}

      _ ->
        # Lambda with wrong arity (Python reduce callback is always
        # binary, so this shouldn't fire — but be conservative).
        emit_name_call_fallback("reduce", [lambda, iter_node, init_node], context)
    end
  end

  defp emit_name_call_fallback(id, raw_args, context) do
    {arg_asts, context} = convert_each(raw_args, context)
    atom = id |> Naming.rewrite() |> String.to_atom()
    {{atom, [], arg_asts}, context}
  end

  # Drop hoisted-import defps whose name is never referenced in the
  # surrounding user code (N2). After call-site inlining (e.g.
  # `reduce(lambda, …) → Enum.reduce/3`) the wrapper becomes dead.
  defp drop_unused_hoisted(hoisted_asts, user_code) do
    Enum.reject(hoisted_asts, fn def_ast -> hoisted_unused?(def_ast, user_code) end)
  end

  defp hoisted_unused?({:defp, _, [{name, _, _} | _]}, user_code) when is_atom(name) do
    not name_referenced?(user_code, name)
  end

  defp hoisted_unused?(_, _), do: false

  defp name_referenced?(asts, name) do
    Enum.any?(asts, fn ast ->
      {_, found?} =
        Macro.prewalk(ast, false, fn
          {^name, _, _} = node, _ -> {node, true}
          other, acc -> {other, acc}
        end)

      found?
    end)
  end

  # `next(iter(x))` and `next(iter(x), default)` — the only iterator-
  # protocol idiom we lower (general `iter`/`next` is rejected by
  # `Pylixir.Builtins`). `iter(x)` makes an iterator; `next(...)` pulls
  # the first element. We lower the whole pair as a single shape so
  # arg conversion doesn't first see `iter(x)` and reject. Empty-
  # iterable behaviour: Python raises `StopIteration`; we raise
  # `Enum.OutOfBoundsError` (1-arg) or return the default (2-arg).
  defp detect_next_iter(%{
         "_type" => "Call",
         "func" => %{"_type" => "Name", "id" => "next"},
         "args" => [
           %{
             "_type" => "Call",
             "func" => %{"_type" => "Name", "id" => "iter"},
             "args" => [x],
             "keywords" => []
           }
           | rest
         ],
         "keywords" => []
       })
       when rest == [] or length(rest) == 1 do
    default =
      case rest do
        [] -> :no_default
        [d] -> d
      end

    {:ok, x, default}
  end

  defp detect_next_iter(_), do: :no

  # `x_ast` is wrapped in `py_iter_to_list` so the Python iteration
  # protocol holds: `iter(dict)` yields KEYS (not `{k, v}` entries),
  # `iter(str)` yields chars, etc. For a list it's an identity wrap.
  defp emit_next_iter(x_node, :no_default, context) do
    {x_ast, context} = convert(x_node, context)
    coerced = {:py_iter_to_list, [], [x_ast]}
    ast = {{:., [], [{:__aliases__, [], [:Enum]}, :fetch!]}, [], [coerced, 0]}
    {ast, context}
  end

  defp emit_next_iter(x_node, default_node, context) do
    {x_ast, context} = convert(x_node, context)
    {d_ast, context} = convert(default_node, context)
    coerced = {:py_iter_to_list, [], [x_ast]}
    ast = {{:., [], [{:__aliases__, [], [:Enum]}, :at]}, [], [coerced, 0, d_ast]}
    {ast, context}
  end

  # Match `type(x).__name__` precisely: Attribute(value=Call(func=Name("type"),
  # args=[x], no kwargs/star), attr="__name__"). The shape that comes up in
  # real code; anything else (`type(x).__mro__`, `obj.__class__.__name__`, ...)
  # still raises so the failure is loud.
  defp detect_type_name_access(%{
         "_type" => "Attribute",
         "attr" => "__name__",
         "value" => %{
           "_type" => "Call",
           "func" => %{"_type" => "Name", "id" => "type"},
           "args" => [arg],
           "keywords" => []
         }
       }),
       do: {:ok, arg}

  defp detect_type_name_access(_), do: :no

  # `zip(*xs)` is the only builtin that has a list-form lowering matching
  # Python's star-unpack semantics — `Enum.zip(xs)` already iterates a
  # list-of-iters in lockstep, same as `zip(*xs)`. For other in-scope
  # names (lambdas, demoted functions), emit `apply(fn_ref, args)`.
  # Top-level `defp`s — `Kernel.apply(__MODULE__, :name, args)`.
  defp emit_starred_call("zip", star_node, _node, context) do
    {arg_ast, context} = convert(star_node, context)
    {{{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [], [arg_ast]}, context}
  end

  # `print(*xs[, sep=..., end=...])` — unpack and print. Routes to
  # `py_print_iter/3` (sep, end_), which py_str's each elem, joins
  # with sep, and appends end_ via IO.write. Defaults match Python:
  # sep=" ", end="\n". Mixed positional+star forms aren't handled
  # here (the call-site requires a single Starred arg).
  defp emit_starred_call("print", star_node, node, context) do
    {arg_ast, context} = convert(star_node, context)
    {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)
    sep_ast = Map.get(kwargs, "sep", " ")
    end_ast = Map.get(kwargs, "end", "\n")
    {{:py_print_iter, [], [arg_ast, sep_ast, end_ast]}, context}
  end

  # `product(*iters[, repeat=N])` — like `zip`, the unpacked argument
  # IS the list-of-iterables `py_product` expects. The general
  # `apply(fn, list)` path would spread the list as separate positional
  # args and crash the 1-arg `product` binding (BadArityError); pass the
  # list straight through instead. Only fires when `product` resolves to
  # the itertools alias, so a user-defined `product` keeps normal splat.
  defp emit_starred_call("product", star_node, node, context) do
    case Map.get(context.stdlib_aliases, "product") do
      {"itertools", "product"} ->
        arg_type = TypeInfer.infer_expr(star_node, context)
        {arg_ast, context} = convert(star_node, context)
        arg_list = TypeInfer.coerce_iter(arg_ast, arg_type)
        {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)
        repeat = Map.get(kwargs, "repeat", 1)
        {{:py_product, [], [arg_list, repeat]}, context}

      _ ->
        emit_starred_call_default("product", star_node, node, context)
    end
  end

  defp emit_starred_call(id, star_node, node, context),
    do: emit_starred_call_default(id, star_node, node, context)

  defp emit_starred_call_default(id, star_node, node, context) do
    arg_type = TypeInfer.infer_expr(star_node, context)
    {arg_ast, context} = convert(star_node, context)
    arg_list = TypeInfer.coerce_iter(arg_ast, arg_type)

    cond do
      name_in_scope?(context, id) ->
        # `id` is bound as a lambda — `apply(fn, args)` works.
        atom = id |> Naming.rewrite() |> String.to_atom()
        ref = {atom, [], nil}
        {{{:., [], [{:__aliases__, [], [:Kernel]}, :apply]}, [], [ref, arg_list]}, context}

      MapSet.member?(context.known_functions, id) ->
        # Top-level `def f(...)` — reachable via `apply(__MODULE__, :f, args)`.
        # (Top-level Pylixir functions are public `def`s since the
        # @doc-propagation switch.)
        atom = id |> Naming.rewrite() |> String.to_atom()
        mod = {:__MODULE__, [], nil}
        {{{:., [], [{:__aliases__, [], [:Kernel]}, :apply]}, [], [mod, atom, arg_list]}, context}

      true ->
        raise UnsupportedNodeError,
          node_type: "Starred",
          hint:
            "`#{id}(*args)` is only supported when `#{id}` is in scope as a lambda, a top-level def, or the builtin `zip`",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  # Chained-call shape: `f(x)(y)`, `(lambda x: ...)(arg)`, etc.
  # The `func` is itself an expression (Call/Lambda/Subscript/IfExp)
  # that returns a callable. Emit `(callable_ast).(args)` — Elixir's
  # anonymous-call invocation. Kwargs unsupported: Python's calling
  # convention here matches the in-scope-lambda call path, which also
  # doesn't accept kwargs.
  defp emit_dynamic_call(node, context) do
    {callable_ast, context} = convert(node["func"], context)
    {arg_asts, context} = convert_each(Map.get(node, "args", []), context)

    case Map.get(node, "keywords", []) do
      [] ->
        {{{:., [], [callable_ast]}, [], arg_asts}, context}

      _ ->
        raise UnsupportedNodeError,
          node_type: "Call",
          hint: "chained call with kwargs (`f(x)(y, k=v)`) is not supported",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  defp emit_attribute_call(target, attr, node, context) do
    # Stdlib root? `target` is the chain *before* the method name; the
    # full path is that prefix plus the method `attr`. Examples:
    # `math.sqrt(4)`: target=Name("math"), prefix=[], path=["sqrt"].
    # `sys.stdin.read()`: target=Attribute(sys, "stdin"), prefix=["stdin"],
    # path=["stdin", "read"].
    synthesized = %{"_type" => "Attribute", "value" => target, "attr" => attr}

    case stdlib_chain(synthesized) do
      {:ok, mod_name, path} ->
        {arg_asts, context} = convert_each(Map.get(node, "args", []), context)
        {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)
        impl = Stdlib.impl(mod_name)

        Lowering.dispatch(
          impl.call(path, arg_asts, kwargs, node),
          "`#{mod_name}.#{Enum.join(path, ".")}` is not a supported stdlib call",
          node,
          context
        )

      :no_stdlib ->
        # `obj.<method>(args)` on a registered class method: route to
        # `__cls_<Class>_<method>(obj, args)`. Only read-only methods
        # are handled here (a mutating method's return value is `self`
        # and the caller must rebind `obj` — that path lives in the
        # Expr clause for statement-form calls, added in a later loop).
        owners = Map.get(context.class_methods, attr, [])

        cond do
          match?([{_, :read_only}], owners) ->
            [{class_name, :read_only}] = owners
            {target_ast, context} = convert(target, context)
            {arg_asts, context} = convert_each(Map.get(node, "args", []), context)
            fn_name = method_fn_name(class_name, attr)
            {{fn_name, [], [target_ast | arg_asts]}, context}

          match?([{_, :mutating}], owners) ->
            # Mutating-method call in an expression context (e.g.
            # `print(dsu.find(x))`, `if dsu.union(a, b): ...`). We
            # can't rebind `obj` here — the call's result needs to
            # be a single value, not a `{value, updated_self}` tuple.
            # Compromise: emit `elem(call, 0)` to extract just the
            # value; the self update is dropped. Callers that need
            # the mutation to persist must call as a statement
            # (`obj.method(args)`) or assign (`x = obj.method(args)`),
            # both of which are handled separately and rebind obj.
            [{class_name, :mutating}] = owners
            {target_ast, context} = convert(target, context)
            {arg_asts, context} = convert_each(Map.get(node, "args", []), context)
            fn_name = method_fn_name(class_name, attr)
            call = {fn_name, [], [target_ast | arg_asts]}
            {{:elem, [], [call, 0]}, context}

          length(owners) > 1 ->
            names = Enum.map_join(owners, ", ", fn {c, _} -> c end)

            raise UnsupportedNodeError,
              node_type: "Call",
              hint:
                "method `.#{attr}()` is defined on multiple registered classes (#{names}); receiver-type inference is too weak to pick one — rename one of the methods or move the call into a method of the owning class",
              lineno: Map.get(node, "lineno")

          true ->
            {target_ast, context} = convert(target, context)
            {arg_asts, context} = convert_each(Map.get(node, "args", []), context)
            {kwargs, context} = convert_keywords(Map.get(node, "keywords", []), context)
            {Nodes.AttributeMethods.dispatch(attr, target_ast, arg_asts, kwargs, node), context}
        end
    end
  end

  # Walk an Attribute chain; if the root is a Name matching a registered
  # `Pylixir.Stdlib` module, return `{:ok, mod_name, attr_path}` where
  # `attr_path` is the list of attribute names *after* the module
  # (always ≥ 1 element since the input is an Attribute node, not a
  # bare Name). Anything else returns `:no_stdlib`.
  defp stdlib_chain(%{"_type" => "Attribute", "value" => value, "attr" => attr}) do
    case attribute_root(value, [attr]) do
      {:ok, root, path} ->
        if Stdlib.supported?(root), do: {:ok, root, path}, else: :no_stdlib

      :error ->
        :no_stdlib
    end
  end

  defp attribute_root(%{"_type" => "Name", "id" => id}, acc), do: {:ok, id, acc}

  defp attribute_root(%{"_type" => "Attribute", "value" => v, "attr" => a}, acc),
    do: attribute_root(v, [a | acc])

  defp attribute_root(_, _), do: :error

  @doc false
  def convert_keywords([], context), do: {%{}, context}

  def convert_keywords(keywords, context) do
    Enum.reduce(keywords, {%{}, context}, fn
      %{"arg" => nil}, _ ->
        raise UnsupportedNodeError,
          node_type: "Call",
          hint: "double-star kwargs unpack (**d) at call sites is not supported"

      %{"arg" => name, "value" => value}, {acc, ctx} ->
        {ast, ctx} = convert(value, ctx)
        {Map.put(acc, name, ast), ctx}
    end)
  end

  defp no_kwargs!(kwargs, _id, _node) when map_size(kwargs) == 0, do: :ok

  defp no_kwargs!(_kwargs, id, node) do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint: "keyword arguments at call sites are not supported for `#{id}`",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  @doc false
  def tuple_pattern([a, b]), do: {a, b}
  def tuple_pattern(refs), do: {:{}, [], refs}

  @doc """
  Strip a redundant `Enum.to_list/1` wrap around a `start..stop//step`
  (or `start..stop`) Range — `range(...)` lowers to
  `Enum.to_list(start..stop//step)` (see `Pylixir.Builtins`) so
  consumers that need a concrete list (`len(r)`, `print(r)`, …) see
  one, but iter-consuming sites (for-loop reduce, list-comp `Enum.map`,
  …) accept ranges directly. For n in the hundreds of thousands (eval
  corpus `seed_13048`) the avoided allocation is the difference
  between fitting and not fitting under the eval-run timeout.
  No-op on any other expression.
  """
  @spec elide_range_to_list(Macro.t()) :: Macro.t()
  def elide_range_to_list(
        {{:., _, [{:__aliases__, _, [:Enum]}, :to_list]}, _, [{:..//, _, _} = range]}
      ),
      do: range

  def elide_range_to_list(
        {{:., _, [{:__aliases__, _, [:Enum]}, :to_list]}, _, [{:.., _, _} = range]}
      ),
      do: range

  def elide_range_to_list(other), do: other

  @doc false
  # Python's throwaway names (`_`, `__`, `___`, …) — emit Elixir's
  # discard pattern, don't bind, don't return in the `names` list.
  # See `LoopAnalysis.discard_name?/1` for the matching exclusion and
  # rationale (Elixir's `_` is pattern-only; `__` collides with the
  # compiler-variable prefix).
  def convert_loop_target(target, context), do: convert_loop_target(target, context, :any)

  @doc """
  Same as `convert_loop_target/2` but takes the iterable's element
  type (`elem_t`, produced by `TypeInfer.elem_of/1`). When a tuple
  loop-target iterates a list-of-lists (`elem_t == {:list, _}`), the
  destructure emits an Elixir list pattern (`[a, b]`) instead of a
  tuple pattern (`{a, b}`) — Python's sequence-unpacking handles both
  shapes, but Elixir's pattern matching is strict. Falls back to the
  tuple pattern for `:any` / `{:tuple, _}` / unions / etc.
  """
  @spec convert_loop_target(map(), Context.t(), TypeInfer.t()) ::
          {Macro.t(), [String.t()], Context.t()}
  def convert_loop_target(%{"_type" => "Name", "id" => id}, context, _elem_t)
      when is_binary(id) and id != "" do
    context = bind_name(context, id)
    atom = id |> Naming.rewrite() |> String.to_atom()
    # All-underscore Python names rewrite to `_us`/`_us2`/... — valid
    # Elixir bindings that suppress the unused-variable warning via
    # the `_` prefix. They're still excluded from the threading
    # set in `LoopAnalysis.discard_name?` so they don't leak into
    # state tuples.
    names = if all_underscores?(id), do: [], else: [id]
    {{atom, [], nil}, names, context}
  end

  def convert_loop_target(%{"_type" => "Tuple", "elts" => elts}, context, elem_t) do
    reject_starred!(elts, "Tuple")

    {refs, names, context} =
      Enum.reduce(elts, {[], [], context}, fn elt, {refs, names, ctx} ->
        {ref, new_names, ctx} = convert_loop_target_elt(elt, ctx)
        {[ref | refs], Enum.reverse(new_names) ++ names, ctx}
      end)

    refs = Enum.reverse(refs)
    pattern = loop_target_destructure(refs, elem_t)
    {pattern, Enum.reverse(names), context}
  end

  def convert_loop_target(target, _context, _elem_t) do
    raise UnsupportedNodeError,
      node_type: "For",
      hint:
        "for-loop target shape `#{Map.get(target, "_type")}` is not supported (use a Name or Tuple of Names)"
  end

  # Choose the Elixir destructure shape for a tuple-form loop target
  # given the iterable's element type. Python's `for a, b in xs:` is
  # sequence-agnostic — it unpacks lists and tuples alike. Elixir
  # patterns aren't, so we pick the shape that matches what's actually
  # in the iterable when we can prove it.
  defp loop_target_destructure(refs, elem_t) do
    if TypeInfer.is_list?(elem_t) do
      refs
    else
      tuple_pattern(refs)
    end
  end

  defp all_underscores?(id),
    do: id |> String.to_charlist() |> Enum.all?(&(&1 == ?_))

  # Per-element helper for tuple-target recursion. Allows nested
  # tuples of Names — `for (a, b), c in pairs:` / `for (r, c), v in
  # bonuses.items():` etc. Each Name is treated like the single-Name
  # case (discard-rules, scope binding); each nested Tuple recurses.
  defp convert_loop_target_elt(%{"_type" => "Name", "id" => id}, context)
       when is_binary(id) and id != "" do
    context = bind_name(context, id)
    atom = id |> Naming.rewrite() |> String.to_atom()
    names = if all_underscores?(id), do: [], else: [id]
    {{atom, [], nil}, names, context}
  end

  defp convert_loop_target_elt(%{"_type" => "Tuple", "elts" => inner_elts}, context) do
    reject_starred!(inner_elts, "Tuple")

    {refs, names, context} =
      Enum.reduce(inner_elts, {[], [], context}, fn elt, {refs, names, ctx} ->
        {ref, new_names, ctx} = convert_loop_target_elt(elt, ctx)
        {[ref | refs], Enum.reverse(new_names) ++ names, ctx}
      end)

    {tuple_pattern(Enum.reverse(refs)), Enum.reverse(names), context}
  end

  defp convert_loop_target_elt(other, _context) do
    raise UnsupportedNodeError,
      node_type: "For",
      hint:
        "for-loop tuple-target element must be a Name or nested Tuple of Names; got `#{Map.get(other, "_type")}`"
  end

  @doc false
  def convert_test(test_node, context) do
    # S1 — type-aware truthy? elision. Order matters: TypeInfer first
    # (handles BoolOp / Call / Name cases the AST-shape check can't),
    # then BoolReturning.bool_returning?/1 (handles `Compare` regardless
    # of operand types — even `a < b` where one operand is `:any`).
    #
    # Soundness: only exact `{:bool}` elides. Unions even containing
    # `{:bool}` keep the wrap — Python's `0 is falsy` vs Elixir's
    # `only false/nil are falsy` would diverge for bool/int union.
    #
    # Constants short-circuit through `truthy?`: emitting bare `true` /
    # `false` as a `cond` clause-head triggers Elixir's
    # `this clause in cond will always match` warning (the while-loop
    # emitter pairs the test with a `true -> fallback` clause, which
    # becomes a duplicate). Wrapping in `truthy?(true)` keeps the test
    # opaque to the compile-time clause-matching analysis.
    inferred_type = TypeInfer.infer_expr(test_node, context)
    {test_ast, context} = convert(test_node, context)

    wrapped =
      cond do
        constant_bool_node?(test_node) ->
          {:truthy?, [], [test_ast]}

        inferred_type == {:bool} ->
          test_ast

        BoolReturning.bool_returning?(test_node) ->
          test_ast

        # Type-aware specialization for the well-defined non-bool
        # truthy patterns (str empty-check, list/tuple empty-check,
        # int/float zero-check, set empty-check). Skipping `{:dict, _, _}`
        # because alist optimisation makes the runtime form
        # context-dependent.
        specialized = typed_truthy_test(test_ast, inferred_type, :positive) ->
          specialized

        true ->
          {:truthy?, [], [test_ast]}
      end

    {wrapped, context}
  end

  defp constant_bool_node?(%{"_type" => "Constant", "value" => v}) when is_boolean(v), do: true
  defp constant_bool_node?(_), do: false

  # Specialized truthy/falsy emit for known scalar/container types.
  # Returns the specialized AST or `nil` (caller falls back to
  # `truthy?(operand)` for positive or `!truthy?(operand)` for negative).
  #
  # `:dict` deliberately omitted — alist-vs-map dispatch deferred.
  # `:bytes` not in the lattice; bytes-typed expressions infer as `:any`.
  #
  # For {:list, _} and {:tuple, _} we route through `Enum.empty?/1` and
  # `tuple_size/1` rather than `arr == []` / `t == {}`: Elixir's
  # type-checker (1.18+) treats `non_empty_list(T) == empty_list()` and
  # `{a, b, c} == {}` as comparisons between distinct types and emits a
  # diagnostic on common patterns like `arr = [1,2]; if not arr: ...`.
  # The function-call forms stay opaque to that analysis.
  defp typed_truthy_test(operand_ast, type, polarity) do
    op =
      case polarity do
        :positive -> :!=
        :negative -> :==
      end

    case type do
      {:str} ->
        {op, [], [operand_ast, ""]}

      {:int} ->
        {op, [], [operand_ast, 0]}

      {:int_lit_nonneg} ->
        {op, [], [operand_ast, 0]}

      {:float} ->
        {op, [], [operand_ast, 0.0]}

      {:list, _} ->
        empty_call = {{:., [], [{:__aliases__, [], [:Enum]}, :empty?]}, [], [operand_ast]}

        case polarity do
          :positive -> {:!, [], [empty_call]}
          :negative -> empty_call
        end

      {:tuple, _} ->
        {op, [], [{:tuple_size, [], [operand_ast]}, 0]}

      {:set} ->
        {op, [], [{{:., [], [{:__aliases__, [], [:MapSet]}, :size]}, [], [operand_ast]}, 0]}

      _ ->
        nil
    end
  end

  @doc false
  def body_to_block([]), do: nil
  def body_to_block([single]), do: single
  def body_to_block(many), do: {:__block__, [], many}

  @doc false
  def maybe_temp_bind(node, context) do
    {ast, context} = convert(node, context)

    if Trivial.trivial?(node) do
      {ast, nil, context}
    else
      {temp_atom, context} = next_temp(context)
      temp_ref = {temp_atom, [], nil}
      {temp_ref, {:=, [], [temp_ref, ast]}, context}
    end
  end

  @doc false
  def next_temp(context) do
    n = context.temp_counter
    atom = String.to_atom("py_tmp_#{n}")
    {atom, %{context | temp_counter: n + 1}}
  end

  # --- Literal-container rejections --------------------------------------

  # `del coll[start:stop:step]` — slice deletion. Reconstruct the list
  # without the selected indices (mirrors Python's `coll[a:b] = []`).
  defp convert_del_target(
         %{
           "_type" => "Subscript",
           "value" => %{"_type" => "Name", "id" => coll_id} = collection,
           "slice" => %{"_type" => "Slice"} = slice_node
         },
         _node,
         context
       ) do
    {start_ast, context} = convert_optional(Map.get(slice_node, "lower"), context)
    {stop_ast, context} = convert_optional(Map.get(slice_node, "upper"), context)
    {step_ast, context} = convert_optional(Map.get(slice_node, "step"), context)
    {coll_ast, context} = convert(collection, context)
    context = TypeInfer.demote(context, coll_id)
    context = bind_name(context, coll_id)

    rhs = {:py_slice_delete, [], [coll_ast, start_ast, stop_ast, step_ast]}
    {{:=, [], [coll_ast, rhs]}, context}
  end

  defp convert_del_target(
         %{
           "_type" => "Subscript",
           "value" => %{"_type" => "Name", "id" => coll_id} = collection,
           "slice" => slice
         },
         _node,
         context
       ) do
    {slice_ast, context} = convert(slice, context)
    {coll_ast, context} = convert(collection, context)
    context = TypeInfer.demote(context, coll_id)
    context = bind_name(context, coll_id)
    {{:=, [], [coll_ast, {:py_delitem, [], [coll_ast, slice_ast]}]}, context}
  end

  defp convert_del_target(other, node, _context) do
    raise UnsupportedNodeError,
      node_type: "Delete",
      hint:
        "`del` target shape `#{Map.get(other, "_type")}` is not supported (only depth-1 subscript on a bare Name)",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # `from <stdlib_mod> import <name> [as <alias>]` — delegates the
  # per-name RHS shape to the stdlib's `import_binding/1` callback.
  # The Converter only owns the alias-tracking + AST assembly here;
  # what each name actually binds to lives in `Pylixir.Stdlib.<Mod>`.
  defp stdlib_from_import_alias(mod, impl, name, alias, context, node) do
    alias_atom = alias |> Naming.rewrite() |> String.to_atom()
    alias_ref = {alias_atom, [], nil}

    rhs =
      case impl.import_binding(name) do
        {:ok, ast} ->
          ast

        :error ->
          raise UnsupportedNodeError,
            node_type: "ImportFrom",
            hint: "`from #{mod} import #{name}` is not supported",
            lineno: Map.get(node, "lineno"),
            col_offset: Map.get(node, "col_offset")
      end

    context = bind_name(context, alias)
    # Remember the stdlib origin so call sites can route through the
    # stdlib's call/4 callback when the user passes more args than the
    # captured arity. Lets `permutations(a, 3)` work after
    # `from itertools import permutations` despite our capture being
    # `&py_permutations/1`.
    context = %{context | stdlib_aliases: Map.put(context.stdlib_aliases, alias, {mod, name})}

    # M3 — skip the runtime binding for imports whose every call site
    # inlines via `Stdlib.<Mod>.call/4`. Currently only
    # `from itertools import repeat` (S5 inlined to `List.duplicate/2`
    # at every call). The empty-block sentinel is filtered out of
    # runtime statements in the Module clause. Caveat: if the user
    # uses `repeat` as a value (`f = repeat; f(x, n)`), it'll fail at
    # runtime — accepted trade-off since the value-form is vanishingly
    # rare and `f` would have to look up an undefined local.
    if dead_import_binding?(mod, name) do
      {{:__block__, [], []}, context}
    else
      {{:=, [], [alias_ref, rhs]}, context}
    end
  end

  defp dead_import_binding?("itertools", "repeat"), do: true
  defp dead_import_binding?(_, _), do: false

  defp reject_starred!(elts, container_type) do
    Enum.each(elts, fn
      %{"_type" => "Starred"} = starred ->
        raise UnsupportedNodeError,
          node_type: "Starred",
          hint:
            "star-unpack inside a #{container_type} literal (`[*xs, ...]`) is not supported; use `xs + [...]` instead",
          lineno: Map.get(starred, "lineno"),
          col_offset: Map.get(starred, "col_offset")

      _ ->
        :ok
    end)
  end

  # `{**d1, "k": v, **d2}` — walks keys/values in source order, batches
  # consecutive non-unpack pairs into one literal map, then chains
  # `Map.merge` calls across the batches. `keys` entries are `nil` at
  # unpack positions; the matching `values` entry is the dict to spread.
  defp emit_dict_with_unpack(keys, values, context) do
    {groups, context} = build_dict_unpack_groups(Enum.zip(keys, values), context, [], [])

    case groups do
      [single] ->
        {single, context}

      [first | rest] ->
        merged =
          Enum.reduce(rest, first, fn group, acc ->
            {{:., [], [{:__aliases__, [], [:Map]}, :merge]}, [], [acc, group]}
          end)

        {merged, context}
    end
  end

  defp build_dict_unpack_groups([], context, current_pairs, acc),
    do: {Enum.reverse(flush_dict_group(current_pairs, acc)), context}

  defp build_dict_unpack_groups([{nil, unpack_value} | rest], context, current_pairs, acc) do
    {unpack_ast, context} = convert(unpack_value, context)
    acc = flush_dict_group(current_pairs, acc)
    build_dict_unpack_groups(rest, context, [], [unpack_ast | acc])
  end

  defp build_dict_unpack_groups([{key, value} | rest], context, current_pairs, acc) do
    {key_ast, context} = convert(key, context)
    {value_ast, context} = convert(value, context)
    build_dict_unpack_groups(rest, context, [{key_ast, value_ast} | current_pairs], acc)
  end

  defp flush_dict_group([], acc), do: acc
  defp flush_dict_group(pairs, acc), do: [{:%{}, [], Enum.reverse(pairs)} | acc]

  # --- Constant unsupported-literal hint --------------------------------

  defp unsupported_literal_hint("complex", %{"repr" => repr}),
    do: "Python complex literal `#{repr}` is not supported"

  defp unsupported_literal_hint("bytes", %{"repr" => repr}),
    do: "Python bytes literal `#{repr}` is not supported"

  defp unsupported_literal_hint("ellipsis", _),
    do: "Python Ellipsis literal `...` is not supported"

  defp unsupported_literal_hint(kind, _),
    do: "Python literal of kind `#{kind}` is not supported"

  # --- Module-wrapper emission helpers ----------------------------------

  # Emit one constructor + one per-method `defp` for each registered
  # Python class. The init body is converted as a normal function
  # body with `self` pre-bound, seeded as `self = %{}` — every
  # `self.x = expr` rewrites to `self = Map.put(self, :x, expr)` via
  # the Attribute-target Assign clause. Methods are lowered the same
  # way; whether they "mutate self" or "return a value" is decided
  # by a static walk of the body (`method_mutates_self?/1`):
  #
  #   * mutating method → return `self` at the end; caller rebinds
  #     `obj = __cls_<C>_<m>(obj, ...)`.
  #   * read-only method → return whatever the body's last expr or
  #     explicit `return` yields; caller uses the value directly.
  #
  # Function name shape `__cls_<Class>_<method>` keeps the namespace
  # distinct from user-defined `defp`s and unambiguous across classes.
  defp convert_class_defs([], context), do: {[], context}

  defp convert_class_defs(class_defs, context) do
    {ast_lists, context} =
      Enum.map_reduce(class_defs, context, &emit_class/2)

    {List.flatten(ast_lists), context}
  end

  defp emit_class(class, context) do
    %{name: class_name, init: init, methods: methods} = class
    mutating = class_mutating_methods(class)

    {init_ast, context} = emit_method(class_name, init, :init, context)

    {method_asts, context} =
      Enum.map_reduce(methods, context, fn m, ctx ->
        kind = if MapSet.member?(mutating, m.name), do: :mutating, else: :read_only
        emit_method(class_name, m, kind, ctx)
      end)

    {[init_ast | method_asts], context}
  end

  defp emit_method(class_name, %{args: args, body: body} = method, kind, context) do
    fn_name =
      case kind do
        :init -> init_fn_name(class_name)
        _ -> method_fn_name(class_name, method.name)
      end

    [%{"arg" => "self"} | rest_args] = args["args"]
    param_atoms = Enum.map(rest_args, fn %{"arg" => a} -> a end)

    # Default values for trailing positional args (`def m(self, i, d=1)`).
    # The defaults list aligns to the TAIL of args; skip the `self`
    # offset since defaults can never apply to it.
    defaults = Map.get(args, "defaults", [])
    defaults_start = length(rest_args) - length(defaults)

    saved_scopes = context.scopes
    saved_return_mode = context.return_mode
    inner_scope = MapSet.new(["self" | param_atoms])

    return_mode =
      case kind do
        :mutating -> :tuple_with_self
        _ -> :unwrapped
      end

    inner_ctx = %{
      context
      | scopes: [inner_scope | context.scopes],
        return_mode: return_mode
    }

    inner_ctx = bind_name(inner_ctx, "self")
    inner_ctx = Enum.reduce(param_atoms, inner_ctx, &bind_name(&2, &1))

    # `:init` seeds `self = %{}` and returns it. `:mutating` methods
    # return `{return_value, updated_self}` (the Return clause in
    # `:tuple_with_self` mode produces the tuple for explicit
    # returns; the implicit-None tail below covers fall-through). The
    # caller destructures both shapes — see `emit_class_method_rebind`
    # and the Assign clause's mutating-method-RHS branch.
    {body_asts, inner_ctx} = convert_each(body, inner_ctx)

    self_atom = "self" |> Naming.rewrite() |> String.to_atom()
    self_ref = {self_atom, [], nil}

    body_block =
      case kind do
        :init ->
          seed = {:=, [], [self_ref, {:%{}, [], []}]}
          body_to_block([seed | body_asts] ++ [self_ref])

        :mutating ->
          # Implicit-None return tail: `{nil, var_self}` is the
          # function's value when the body falls through without an
          # explicit `return`. If the original Python body's last
          # statement IS a `Return`, the tail would actually
          # *shadow* that return's `{value, var_self}` tuple (which
          # the Return clause already emitted). Skip the tail in
          # that case so the explicit return value flows through.
          if List.last(body) |> is_map() and Map.get(List.last(body), "_type") == "Return" do
            body_to_block(body_asts)
          else
            body_to_block(body_asts ++ [{nil, self_ref}])
          end

        :read_only ->
          body_to_block(body_asts)
      end

    self_param =
      case kind do
        :init -> []
        _ -> [self_ref]
      end

    {param_refs, inner_ctx} =
      param_atoms
      |> Enum.with_index()
      |> Enum.reduce({[], inner_ctx}, fn {name, i}, {acc, ctx} ->
        atom = name |> Naming.rewrite() |> String.to_atom()
        ref = {atom, [], nil}

        if i >= defaults_start do
          default_node = Enum.at(defaults, i - defaults_start)
          {default_ast, ctx} = convert(default_node, ctx)
          {[{:\\, [], [ref, default_ast]} | acc], ctx}
        else
          {[ref | acc], ctx}
        end
      end)

    param_refs = Enum.reverse(param_refs)

    defp_ast =
      {:defp, [],
       [
         {fn_name, [], self_param ++ param_refs},
         [do: body_block]
       ]}

    {defp_ast,
     %{
       inner_ctx
       | scopes: saved_scopes,
         return_mode: saved_return_mode
     }}
  end

  # Does this method body bind `self` (i.e. contains a `self.x = ...`
  # or `self.x[...] = ...` form)? Mutation detection drives the
  # caller-side rebind: `obj.method(args)` on a mutating method
  # becomes `obj = __cls_<C>_<method>(obj, args)`, on a read-only
  # method stays as a value expression.
  defp method_mutates_self?(body) do
    Enum.any?(body, &walk_for_self_mutation/1)
  end

  # Per-class mutating-method set. Direct mutators (those with
  # `self.x = ...` / `self.x[...] = ...` / `self.x op= ...` in their
  # bodies) seed the set; then we fixpoint, marking any method whose
  # body calls `self.<mutator>(...)` as mutating too. Without the
  # transitive step, a `def add(self, ...): self.range_add(...)`
  # wrapper would be classified `:read_only` even though the wrapped
  # call mutates — the caller would skip the rebind and lose the
  # mutation.
  defp class_mutating_methods(class) do
    methods = class.methods

    initial =
      methods
      |> Enum.filter(&method_mutates_self?(&1.body))
      |> Enum.map(& &1.name)
      |> MapSet.new()

    fixpoint_mutating(methods, initial)
  end

  defp fixpoint_mutating(methods, current) do
    new =
      Enum.reduce(methods, current, fn m, acc ->
        cond do
          MapSet.member?(acc, m.name) -> acc
          method_calls_self_method?(m.body, acc) -> MapSet.put(acc, m.name)
          true -> acc
        end
      end)

    if MapSet.equal?(new, current), do: current, else: fixpoint_mutating(methods, new)
  end

  defp method_calls_self_method?(body, mutating_set) do
    Enum.any?(body, fn node ->
      Pylixir.AST.Walk.walk_scope(node, false, fn n, acc ->
        acc or self_calls_mutating_method?(n, mutating_set)
      end)
    end)
  end

  defp self_calls_mutating_method?(
         %{
           "_type" => "Call",
           "func" => %{
             "_type" => "Attribute",
             "value" => %{"_type" => "Name", "id" => "self"},
             "attr" => method
           }
         },
         mutating_set
       ),
       do: MapSet.member?(mutating_set, method)

  defp self_calls_mutating_method?(_, _), do: false

  defp walk_for_self_mutation(node) do
    Pylixir.AST.Walk.walk_scope(node, false, fn n, acc -> acc or self_mutating?(n) end)
  end

  defp self_mutating?(%{
         "_type" => "Assign",
         "targets" => targets
       }) do
    Enum.any?(targets, &assign_target_touches_self?/1)
  end

  defp self_mutating?(%{
         "_type" => "AugAssign",
         "target" => target
       }) do
    assign_target_touches_self?(target)
  end

  defp self_mutating?(_), do: false

  defp assign_target_touches_self?(%{
         "_type" => "Attribute",
         "value" => %{"_type" => "Name", "id" => "self"}
       }),
       do: true

  defp assign_target_touches_self?(%{
         "_type" => "Subscript",
         "value" => %{"_type" => "Attribute", "value" => %{"_type" => "Name", "id" => "self"}}
       }),
       do: true

  defp assign_target_touches_self?(_), do: false

  @doc false
  def init_fn_name(class_name) do
    # Elixir function names must start lowercase (a leading capital
    # is parsed as an alias). Python classes are PascalCase by
    # convention, so prefix with `__cls_` (Pylixir-reserved namespace
    # — the leading underscore avoids collision with user `defp`s
    # and the `__cls_` prefix is unique enough to make grep useful).
    String.to_atom("__cls_" <> class_name <> "__init__")
  end

  @doc false
  def method_fn_name(class_name, method_name) do
    String.to_atom("__cls_" <> class_name <> "_" <> method_name)
  end

  # PR 12 isinstance narrowing lives in
  # `Pylixir.TypeInfer.IsinstanceNarrowing`. The If clause above
  # delegates via `TypeInfer.IsinstanceNarrowing.narrow/2`.

  # `seed_module_attr_types` moved to `Pylixir.TypeInfer.seed_module_attr_types/2`
  # so `Pylixir.Pipeline` can call it as a pre-pass.

  defp convert_module_attrs([], context), do: {[], context}

  defp convert_module_attrs([{name, value_node} | rest], context) do
    # ModuleAnalysis only promotes values that `Pylixir.LiteralFold` can
    # evaluate, so the fold here is guaranteed to succeed — bypassing
    # `convert/2` (which would emit runtime helper calls invalid at
    # module-attribute scope) is the whole reason promotion exists.
    {:ok, value} = Pylixir.LiteralFold.fold(value_node)
    value_ast = Macro.escape(value)
    attr = {:@, [], [{:"var_#{name}", [], [value_ast]}]}
    {rest_asts, context} = convert_module_attrs(rest, context)
    {[attr | rest_asts], context}
  end

  @doc false
  def convert_optional(nil, context), do: {nil, context}
  def convert_optional(node, context), do: convert(node, context)

  @doc false
  def convert_each(nodes, context) do
    {asts, context} =
      Enum.reduce(nodes, {[], context}, fn node, {acc, ctx} ->
        {ast, ctx} = convert(node, ctx)
        {[ast | acc], ctx}
      end)

    {Enum.reverse(asts), context}
  end

  @doc """
  Convert a top-level statement list, injecting append-build freeze
  statements after the indices recorded in `ctx.append_build_freeze_after`.

  After emitting the AST for statement `i`, looks up `freeze_after[i]`;
  for each `{xs, kind}` in that map, appends a synthetic freeze AST.
  The freeze form depends on the finalizer kind:

    * `:append_tail` → `xs = py_alist_new(Enum.reverse(xs))` (restore
      insertion order after the prepend-build).
    * `:sort_tail`   → `xs = py_alist_new(xs)` (the preceding
      `xs.sort()` already canonicalized order; re-reversing would
      de-sort).

  Falls back to plain `convert_each/2` when the freeze map is empty —
  no behaviour change for scopes without an append-then-readonly hit.
  """
  @spec convert_each_with_freezes([map()], Context.t()) :: {[Macro.t()], Context.t()}
  def convert_each_with_freezes(nodes, context) do
    freeze_map = context.append_build_freeze_after

    if map_size(freeze_map) == 0 do
      convert_each(nodes, context)
    else
      {asts, context} =
        nodes
        |> Enum.with_index()
        |> Enum.reduce({[], context}, fn {node, idx}, {acc, ctx} ->
          {ast, ctx} = convert(node, ctx)

          case Map.get(freeze_map, idx) do
            nil ->
              {[ast | acc], ctx}

            kinds_by_name ->
              {freeze_asts, ctx} = emit_append_build_freezes(kinds_by_name, ctx)
              # Stack: latest at head, so prepend in order.
              new_acc = Enum.reduce(freeze_asts, [ast | acc], &[&1 | &2])
              {new_acc, ctx}
          end
        end)

      {Enum.reverse(asts), context}
    end
  end

  # Emit one freeze statement per `{name, kind}`, and rebind each
  # name's type to `{:py_alist, elem_t}` so coerce_iter and subscript
  # reads route through alist clauses downstream. The element type
  # is carried over from the pre-freeze `{:list, elem_t}` binding
  # (refined by `TypeInfer.refine_after_append/3` over the build
  # region) so e.g. the type-directed loop-target lowering can keep
  # picking precise destructure patterns post-freeze.
  defp emit_append_build_freezes(kinds_by_name, context) do
    Enum.reduce(kinds_by_name, {[], context}, fn {name, kind}, {acc, ctx} ->
      atom = name |> Pylixir.Naming.rewrite() |> String.to_atom()
      ref = {atom, [], nil}

      inner =
        case kind do
          :append_tail ->
            {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [ref]}

          :sort_tail ->
            ref
        end

      assign_ast = {:=, [], [ref, {:py_alist_new, [], [inner]}]}

      # Prefer the `.append`-driven element-type refinement (see
      # `TypeInfer.refine_after_append/3`) when available; fall back
      # to the static `:types` binding.
      elem_t =
        case Map.fetch(ctx.append_build_element_types, name) do
          {:ok, e} ->
            e

          :error ->
            case Map.get(ctx.types, name) do
              {:list, e} -> e
              _ -> :any
            end
        end

      ctx =
        ctx
        |> TypeInfer.bind(name, {:py_alist, elem_t})
        |> bind_name(name)
        # Post-freeze, the runtime value is `{:py_alist, _}` — drop the
        # `{:list, _}` shadow in `append_build_element_types` so
        # `infer_expr(Name)` sees the freshly-bound alist type from
        # `:types`, not the stale list-flavored refinement.
        |> Map.update!(:append_build_element_types, &Map.delete(&1, name))

      {[assign_ast | acc], ctx}
    end)
  end

  # `@moduledoc "..."` from a Python module-level docstring. Returns
  # an empty list when no docstring was extracted so callers can splice
  # unconditionally.
  defp moduledoc_ast(nil), do: []
  defp moduledoc_ast(doc) when is_binary(doc), do: [{:@, [], [{:moduledoc, [], [doc]}]}]

  # Mutable-module-dict process-dict reads/writes live in
  # `Pylixir.MutableModuleDict`. Callers across Converter and
  # `Pylixir.Nodes.Assign` go through `MutableModuleDict.get_ast/1`
  # and `MutableModuleDict.put_ast/2`.

  defp py_main_def([], _uses_exit) do
    {:def, [], [{:py_main, [], nil}, [do: nil]]}
  end

  defp py_main_def(stmts, uses_exit) do
    body =
      case stmts do
        [single] -> single
        many -> {:__block__, [], many}
      end

    body = if uses_exit, do: wrap_exit_catch(body), else: body
    {:def, [], [{:py_main, [], nil}, [do: body]]}
  end

  # py_main catches `{:pylixir_exit, code}` so Python's `exit(code)`
  # (lowered to a throw by `Builtins.emit("exit", ...)`) returns the
  # code instead of killing the process. M4 — only emitted when
  # `ModuleAnalysis.uses_exit` is true; modules without exit calls
  # ship a bare `def py_main do ... end`.
  defp wrap_exit_catch(body) do
    code_ref = {:code, [], nil}
    catch_clause = ControlFlow.catch_exit(code_ref, code_ref)
    {:try, [], [[do: body, catch: [catch_clause]]]}
  end
end
