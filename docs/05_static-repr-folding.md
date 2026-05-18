# Static Python repr / str / format folding via flow-analyzed literal propagation

## Context

The user pointed at `py_repr/1`'s binary clause (`lib/pylixir/runtime_helpers.ex:603-607`):

```elixir
def py_repr(x) when is_binary(x) do
  if String.contains?(x, "'") and not String.contains?(x, "\"") do
    "\"" <> x <> "\""
  else
    "'" <> String.replace(String.replace(x, "\\", "\\\\"), "'", "\\'") <> "'"
  end
end
```

…and asked why the single-quote check runs at runtime when many arguments are string literals known at transpile time.

Deep research found:

1. **Pylixir has no compile-time repr / str / format folding pass.** `Builtins.emit("repr", [v], _kw)` (`builtins.ex:736`), `Builtins.emit("str", …)`, `Builtins.emit("print", …)`, the f-string lowering, `%`-format, and `.format()` all route to runtime helpers unconditionally — none inspect whether their arg is a literal.

2. **The existing runtime `py_repr/1` binary clause is also incomplete vs. Python.** It only escapes `\\` and `'`. Python's `repr()` also escapes `\n`, `\t`, `\r`, `\f`, `\v`, `\b`, `\a`, `\0`, and `\xNN` for the C0/C1 control ranges. Pylixir emits literal newlines inside repr output today — wrong, but no existing fixture catches it (verified by scanning `test/fixtures/python/`).

3. **`Pylixir.LiteralFold.fold/1`** (`literal_fold.ex:25`) already folds Python AST → BEAM term for Constants, container literals, and arithmetic / bitwise / logical ops on foldable scalars. It's the right primitive for compile-time literal recognition. It does NOT compute Python repr / str strings — that's a separate algorithm.

4. **The Elixir-AST shapes for containers differ from BEAM terms.** Tuples ≥3 elements are emitted as `{:{}, [], elts}` AST nodes, dicts as `{:%{}, [], pairs}`, sets as `MapSet.new(...)` AST calls. Pattern-matching on the post-conversion Elixir AST would miss these. Folding must happen at the Python-AST level, before conversion, using `LiteralFold.fold/1`.

5. **This applies to many emit sites, not just `py_repr`'s string clause.** F-string `!r`, `%r`/`%s`/`%d` percent format, `.format()` on a literal template, `print(container_literal)` (which calls Python's `str()` which equals `repr()` for containers), and `str()` / `repr()` / `format()` builtins all share the shape "literal in → static string out".

## Decisions log

| Tag | Topic | Resolution |
|---|---|---|
| Q1 | Architecture | **Pre-pass at the Python AST level.** Not BEAM-term pattern-match — the AST shapes diverge from BEAM for non-trivial containers, so we fold at the Python side via `LiteralFold.fold/1`. |
| Q2 | Scope | **(iv-a)** — local fold at every emit site (`repr/str/format` builtins, `print` args, f-string segments, `%`-format, `.format()`). |
| Q3 | Flow analysis depth | **Full (iv-c)** — Phase 1 (direct binding) + Phase 2 (constant-returning function) + Phase 3 (closure-capture-aware). |
| Q4 | String escape correctness | **Fix the bug.** Implement Python-correct escapes (`\n` `\t` `\r` `\f` `\v` `\b` `\a` `\0`, plus `\xNN` for all other C0/C1 — 0x00–0x1F + 0x7F–0x9F) once in `LiteralFold.str_repr/1` and back-port the same algorithm to `runtime_helpers.py_repr/1`'s binary clause and `py_repr_str/1` so static fold and runtime stay in sync. |
| Q5 | Phase 2 trigger | **Any-arg constant function with foldable return + side-effect-free call args.** Body must be `[<docstring?>, Return(foldable)]`. Call args at fold sites must themselves be foldable (preserves any side-effects-via-args by refusing the fold when args are non-trivial). |
| Q6 | Phase 3 closure-capture gate | **Strict — walk all closure bodies in the module.** Reject the fold if any Lambda / FunctionDef body anywhere syntactically mutates, aliases, or escapes a tracked name. Soundness via over-conservative rejection of time-ordering. |
| Q7 | Pipeline position | **Standalone pre-pass before `ModuleAnalysis.analyze/1`**. New module `Pylixir.LiteralPropagation`. Wired in `Pylixir.Converter`'s Module clause: `body = LiteralPropagation.rewrite(body)` before `ModuleAnalysis.analyze(body)`. |
| Q8 | Algorithm reuse | **Reuse runtime helpers at compile time.** `LiteralFold` gets new `repr_of/1` and `str_of/1` (which back-port to runtime per Q4). The heavier `%`-format / `.format()` machinery (~200 LOC of existing `py_str_percent_format` / `py_format_value` / `format_percent_typed`) is called *directly* from the pre-pass on literal inputs — single source of truth, divergence-free. |
| Q9 | Floats | **Skip.** Python float repr requires the `py_str_float` / `python_sci` / `shift_decimal` chain; duplicating doubles maintenance for niche win. Floats fall through to runtime. |

## Approach

### Module layout

**Modified:**
- `lib/pylixir/literal_fold.ex` — add `repr_of/1`, `str_of/1`, `str_repr/1`, `str_escape/1`.
- `lib/pylixir/runtime_helpers.ex` — back-port the Python-correct escape table to `py_repr/1`'s binary clause (line 603) and `py_repr_str/1` (line 643).
- `lib/pylixir/converter.ex` — Module clause routes `body` through `LiteralPropagation.rewrite/1` before passing to `ModuleAnalysis.analyze/1`.

**New:**
- `lib/pylixir/literal_propagation.ex` — the pre-pass. ~400–500 LOC across:
  - Scope-aware def-use walker (extends `Pylixir.AST.Walk` with closure recursion).
  - Mutation / alias / escape detection (the Phase 1+3 gate machinery).
  - Constant-function table (the Phase 2 gate machinery).
  - Fixpoint iteration over rewrites + gate recomputation.
  - Emit-site recognizers (the (iv-a) shapes).

### `LiteralFold` extensions

```elixir
@spec repr_of(term()) :: {:ok, binary()} | :error
def repr_of(true), do: {:ok, "True"}
def repr_of(false), do: {:ok, "False"}
def repr_of(nil), do: {:ok, "None"}
def repr_of(v) when is_integer(v), do: {:ok, Integer.to_string(v)}
def repr_of(v) when is_binary(v), do: {:ok, str_repr(v)}
def repr_of(v) when is_list(v), do: fold_seq(v, "[", "]")
def repr_of(v) when is_tuple(v) and tuple_size(v) == 1,
  do: with({:ok, r} <- repr_of(elem(v, 0)), do: {:ok, "(" <> r <> ",)"})
def repr_of(v) when is_tuple(v), do: fold_seq(Tuple.to_list(v), "(", ")")
def repr_of(%MapSet{} = s) do
  case MapSet.to_list(s) do
    [] -> {:ok, "set()"}
    xs -> fold_seq(xs, "{", "}")
  end
end
def repr_of(v) when is_map(v) do
  with {:ok, pairs} <- fold_pairs(v), do: {:ok, "{" <> Enum.join(pairs, ", ") <> "}"}
end
def repr_of(_), do: :error   # floats, structs, anything else

@spec str_of(term()) :: {:ok, binary()} | :error
def str_of(v) when is_binary(v), do: {:ok, v}
def str_of(v), do: repr_of(v)

@spec str_repr(binary()) :: binary()
def str_repr(s) do
  escaped = str_escape(s)
  has_single = String.contains?(escaped, "'")
  has_double = String.contains?(escaped, "\"")
  if has_single and not has_double do
    "\"" <> escaped <> "\""
  else
    "'" <> String.replace(escaped, "'", "\\'") <> "'"
  end
end

defp str_escape(s) do
  s
  |> String.replace("\\", "\\\\")
  |> String.replace("\n", "\\n")
  |> String.replace("\t", "\\t")
  |> String.replace("\r", "\\r")
  |> String.replace("\f", "\\f")
  |> String.replace("\v", "\\v")
  |> String.replace("\b", "\\b")
  |> String.replace("\a", "\\a")
  |> String.replace("\0", "\\x00")
  |> hex_escape_remaining_controls()
end

defp hex_escape_remaining_controls(s) do
  for <<cp::utf8 <- s>>, into: "" do
    cond do
      (cp >= 0x01 and cp <= 0x08) or (cp >= 0x0E and cp <= 0x1F) or
        (cp >= 0x7F and cp <= 0x9F) ->
        "\\x" <> (cp |> Integer.to_string(16) |> String.pad_leading(2, "0"))
      true ->
        <<cp::utf8>>
    end
  end
end
```

Back-port to runtime: replace `py_repr/1`'s binary clause (`runtime_helpers.ex:603-607`) and `py_repr_str/1` (`runtime_helpers.ex:643+`) with delegations to the same algorithm.

### `LiteralPropagation` — the pre-pass

```elixir
defmodule Pylixir.LiteralPropagation do
  alias Pylixir.{LiteralFold, RuntimeHelpers}

  @max_iters 4   # fixpoint cap; folds-enabling-folds rarely chain past 3

  @spec rewrite([map()]) :: [map()]
  def rewrite(body) do
    Enum.reduce_while(1..@max_iters, body, fn _i, b ->
      case one_pass(b) do
        ^b -> {:halt, b}     # fixpoint reached
        next -> {:cont, next}
      end
    end)
  end

  defp one_pass(body) do
    info = scan(body)
    rewrite_with(body, info)
  end

  defp scan(body) do
    %{
      literal_bindings: collect_literal_bindings(body),  # Phase 1+3
      mutation_sites: collect_mutations(body),           # Phase 1+3
      alias_sites: collect_aliases(body),                # Phase 1+3
      escape_sites: collect_escapes(body),               # Phase 1+3
      constant_functions: collect_constant_fns(body),    # Phase 2
    }
  end
  # ...
end
```

### Flow-table builders

**`collect_literal_bindings/1`** — Phase 1+3: walk the AST (recursing into closures). For each scope, find names assigned exactly once where the value is `LiteralFold.fold`-able. Track scope path for shadow-aware lookups.

**`collect_mutations/1`** — Phase 1+3: record names appearing in mutation positions:
- `AugAssign(target=Name(N))`
- `Assign(targets=[Subscript(value=Name(N))])` / `Attribute(value=Name(N))`
- `Delete(targets=[Subscript(Name(N))])`
- `Call(Attribute(value=Name(N), method))` where `method ∈ @mutating_methods`

```elixir
@mutating_methods MapSet.new(~w(
  append extend insert pop popitem clear sort reverse remove update
  setdefault add discard intersection_update difference_update
  symmetric_difference_update
))
```

**`collect_aliases/1`** — Phase 1+3: walk for `Assign(target=Name(M), value=node_containing_Name(N))`. Conservative: any non-trivial expression containing `Name(N)` in load position counts.

**`collect_escapes/1`** — Phase 1+3: walk for `Call(_func, args_containing_Name(N))`. Conservative: by default any function call escapes (unless `func` resolves to an in-module non-mutating function we can prove safe).

**`collect_constant_fns/1`** — Phase 2: walk top-level FunctionDefs. For each, body must be `[<optional docstring>, Return(value_node)]` where `LiteralFold.fold(value_node) == {:ok, v}`. Add `name → v`.

### Gate logic in `resolve/2`

```elixir
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

defp resolve_via_flow(%{"_type" => "Call", "func" => %{"_type" => "Name", "id" => f}, "args" => args}, info) do
  with {:ok, v} <- Map.fetch(info.constant_functions, f),
       true <- Enum.all?(args, &side_effect_free?(&1, info)) do
    {:ok, v}
  else
    _ -> :error
  end
end

defp resolve_via_flow(_, _), do: :error

defp side_effect_free?(node, info), do: match?({:ok, _}, resolve(node, info))
```

### Emit-site rewriter (the (iv-a) surface)

| AST shape | Fold attempt |
|---|---|
| `Call(Name("repr"), [arg])` | `resolve(arg) >>= repr_of` |
| `Call(Name("str"), [arg])` | `resolve(arg) >>= str_of` |
| `Call(Name("format"), [arg])` | `resolve(arg) >>= str_of` |
| `Call(Name("format"), [arg, spec])` | `resolve(arg)` × `resolve(spec)` >>= `RuntimeHelpers.py_format_value` |
| `Call(Name("print"), args, keywords)` | each arg rewritten via str-fold; sep/end keywords also folded if literal |
| `JoinedStr(values=[seg, …])` | per-segment fold; `FormattedValue(value, conversion, format_spec)` → fold value, apply conversion (`!s`/`!r`/`!a`), apply format_spec if literal |
| `BinOp("%", lit_str, args_node)` | `resolve(lit_str)` × `resolve(args_node)` >>= `RuntimeHelpers.py_str_percent_format` |
| `Call(Attribute(value=lit_str_node, attr="format"), args, keywords)` | similar — fold via existing `.format()` lowering on literals |

### Pipeline wiring

In `lib/pylixir/converter.ex`'s Module clause:

```elixir
def convert(%{"_type" => "Module"} = node, context, %ModuleAnalysis{} = _analysis) do
  body = Map.get(node, "body", [])
  body = Pylixir.LiteralPropagation.rewrite(body)   # NEW
  analysis = ModuleAnalysis.analyze(body)
  ...
end
```

Plus update entry points that call `ModuleAnalysis.analyze` upstream — they need the rewritten body too.

## Verification

1. **Unit tests for `LiteralFold` extensions** (`test/pylixir/literal_fold_test.exs`):
   - Golden table for `str_repr/1`: plain strings, single-quote-in-string, double-quote-in-string, both-quotes-in-string, backslash, newline, tab, CR, NUL, mixed control chars. Compared against actual Python `repr()` output.
   - `repr_of/1` for bool/None, integers, strings, lists, tuples (1/2/n-element), MapSets, maps.
   - `str_of/1` differs from `repr_of/1` only on binary input — single test.

2. **Unit tests for `LiteralPropagation.rewrite/1`** (new file):
   - (iv-a) fires: `repr("foo")` → `Constant("'foo'")`; `print([1,2,3])` → args rewritten; `"x=%d" % 5` → `Constant("x=5")`; f-string `f"{1!r}"` → `Constant("1")`.
   - Phase 1 fires: `xs = [1,2,3]; print(xs)` → `print("[1, 2, 3]")` AND `xs = …` becomes dead.
   - Phase 1 GATE: `xs = [1,2,3]; xs.append(4); print(xs)` → no fold. `xs = [1,2,3]; foo(xs); print(xs)` → no fold.
   - Phase 2 fires: `def f(): return [1,2,3]; print(f())` → `print("[1, 2, 3]")`.
   - Phase 2 GATE: `def f(x): return [1,2,3]; print(f(side_effect()))` → no fold.
   - Phase 3 fires: `xs = [1,2,3]; def g(): print(xs); g()` → `g`'s body folds.
   - Phase 3 GATE: `xs = [1,2,3]; def g(): xs.append(4); ...; print(xs)` → no fold.
   - Fixpoint chain: `xs = [1,2,3]; def f(): return xs; print(f())` folds end-to-end.

3. **Existing fixture verification**:
   - `test/fixtures/python/138_repr_builtin.py`, `150_set_repr.py`, `109_fstring_conversions.py` — regenerate, byte-compare runtime output.
   - `162_church_numerals.py` — confirm no regression.
   - Spot-check all fixtures — expected pattern is "shorter generated `.exs` file, identical stdout".

4. **Full suite**: `mix test test/pylixir/` — 940 existing tests must pass.

5. **Runtime back-port verification**: `Pylixir.RuntimeHelpers.py_repr("hello\nworld")` must return `"'hello\\nworld'"` (with `\n` escaped). Today it returns the wrong thing; fix verified by the assertion change.

## Implementation order

1. **`LiteralFold.repr_of/1` + `str_of/1` + `str_repr/1` + tests** — pure functions, easy to TDD.
2. **Back-port `str_repr`/`str_escape` algorithm to `runtime_helpers.ex`** — runtime + static stay in sync.
3. **`LiteralPropagation` flow-table builders** — pure walkers, tested independently.
4. **`LiteralPropagation.resolve/2` + (iv-a) emit-site rewriters** — first end-to-end fold.
5. **Phase 1 gates** — direct binding case wired in.
6. **Phase 2 constant-function table** — function-return fold.
7. **Phase 3 closure recursion** — extend walkers to recurse.
8. **Fixpoint driver** — wire the four phases into a single iteration loop.
9. **Pipeline wiring** in `converter.ex` Module clause.
10. **Snapshot regeneration** + full suite verification.

## Why this is verifiable

- **Single source of truth per algorithm**: `LiteralFold.str_repr/1` for the repr binary, `RuntimeHelpers.py_str_percent_format/3` etc. for the bigger format helpers. Compile-time and runtime paths invoke the same code.
- **Each phase's gate is a syntactic walk** with a clear pass/fail. False-negatives are silent; false-positives are what the gates prevent — and the gates are deliberately over-conservative.
- **Fixpoint cap (4 iters)** guards against runaway. Folds chain at most a couple of times in practice.
- **Existing-fixture diff is a regression detector**: any fixture whose stdout changes after this pass indicates an incorrect fold.
- **The `runtime_helpers.py_repr` back-port is the only behavior change visible at runtime** (and it's a bug fix — output becomes Python-correct, not less correct).

## Out of scope

- **Float repr.** `py_str_float` / `python_sci` / `shift_decimal` chain stays runtime. Float literals fall through.
- **Arg-substituting constant functions** (e.g., `def f(x): return [1, 2, x]`). Body-side AST substitution adds a separate walker. Punt unless a fixture motivates it.
- **`.format(**dict)` / advanced format specifiers** (alignment, width, fill, sign, grouping). Simple cases work via runtime helper reuse; deeply-nested format specs fall through.
- **Cross-module flow analysis.** Stays scope-local to one module's AST.
