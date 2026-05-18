# Verifiable slimming of generated Elixir output

## Context

`mix eval.show ./test/fixtures/python/162_church_numerals.py --out test.exs` emits 121 lines / 2850 bytes. The biggest theoretical wins (eliminating py_repr/py_str at the `print(<{:list, :any}>)` site) require either pragmatic-unsafe gating or full HOF-aware type inference — neither fits a "verifiable single plan".

After grilling, the original plan's items #1 (inline `py_repr` for `:any`-element lists) and #2 (drop scalar `py_str` clauses by flow analysis) were dropped because they cannot be verified with current infrastructure:

- **#1**: `intFromChurch -> :any` (because `succ` has a `{:str}` branch via `chr(...)`). No way to prove element type at print site without modeling HOF/closure semantics.
- **#2**: requires def-use analysis to prove no bool/None/atom flows into the `py_str` recursive call.

This plan ships a **set of verifiable wins** that compound to ~10 lines saved unconditionally, plus a new opt-in mechanism (Python annotation passthrough) that unlocks ~50 more lines when the user annotates their source — a clean contract whose verification target is the annotation itself, not the converter's inference.

## Decisions log

| Tag | Topic | Resolution |
|---|---|---|
| Q1 | Soundness gate for inline-repr fallback | **Strict verifiability** — never emit code based on unproven type assumptions. |
| Q2 | Original plan items #1 and #2 | **Dropped** — not verifiable with current type infrastructure. Replace with verifiable items below. |
| Q3 | Annotation scope | **(b) Return + param types**. Bare types only (`int`, `float`, `str`, `bool`, `list`, `tuple`, `dict`, `set`, `None`). Subscripted generics, dotted names, future-annotations strings → ignored (fall through to inference). |
| Q4 | Annotation semantics on conflict | **Trust unconditionally**. Seed `fn_signatures` and `Context.types` from annotations; never overridden by inference. Verification target: "Pylixir is correct given accurate annotations" (matches mypy/pyright contract). |
| Q5 | Closure-inline scope | **Generic single-use closure pass**. Detect `Assign(Name = Lambda | demoted-FunctionDef)` where `Name` is referenced exactly once and the reference is a **direct call** (not a `&Name/N` capture). |
| Q6 | Multi-clause def scope | **Minimal**: `def f(<single param>): return <body> if isinstance(<param>, T) else <else>`. Docstring before return is allowed. |

## Approach

### Item #3 — Multi-clause def with guards for `return <IfExp(isinstance)>`

In the function-body lowering path, when:

- Function body is `[<optional docstring>; Return(IfExp(test, body, orelse))]`
- `test` is `Call(func=Name("isinstance"), args=[Name(id=PARAM), TYPE_REF])`
- `PARAM` matches a single function arg name
- `TYPE_REF` is a bare type name from the supported set

emit two function clauses:

```elixir
def f(x) when <guard for T>(x), do: <body>
def f(x), do: <else>
```

Type→guard map:
- `int` → `is_integer(x) or is_boolean(x)` (matches Python's `isinstance(x, int) == True` for bools)
- `float` → `is_float(x)`
- `str` → `is_binary(x)`
- `list` → `is_list(x)`
- `tuple` → `is_tuple(x)`
- `dict` → `is_map(x) and not is_struct(x)`
- `set` → `%MapSet{}` head-match (no guard) — second clause becomes the catchall
- `bool` → `is_boolean(x)`
- `None` → `is_nil(x)`

Files: `lib/pylixir/converter.ex` (function-body lowering path) and/or `lib/pylixir/nodes/functions.ex`.

### Item A — Underscore-prefix unused lambda/closure params

When converting a `Lambda` (or demoted closure FunctionDef), walk the body for `Name` references to each param. If a param is never referenced, emit it as `_<name>`.

For church-numerals: `lambda f: identity` → `fn _f -> &identity/1 end`.

Files: wherever Lambda lowers — likely `lib/pylixir/nodes/lambda.ex` or `converter.ex`'s Lambda clause.

### Items B + C — Generic single-use closure elimination

New Python-AST-level pass (cleaner than post-conversion Elixir-AST peephole because lexical scopes are intact). Detect:

```python
Assign(target=Name(N), value=(Lambda(args=A, body=L_body) | FunctionDef(name=N, args=A, body=L_body)))
... # zero or more statements that do not reference N
... Call(func=Name(N), args=CALL_ARGS) ...  # exactly one occurrence of N anywhere after Assign
```

Gate:
1. `N` is referenced **exactly once** in the enclosing scope after its Assign.
2. The single reference is a **direct call** (`Call(func=Name(N), ...)`) — not `&Name/N` capture or attribute access.
3. Each entry in `CALL_ARGS` is a `Name` AST whose `id` matches the corresponding param in `A` (trivial substitution — no alpha-rename needed). If any arg is a complex expression or a name-mismatch, **skip** inlining (conservative).

Action: replace the call site with `L_body`'s expression form. Remove the Assign. If `FunctionDef` form, convert its `return <expr>` body to the expression `<expr>`.

For church-numerals:
- `foldl`: `go = fn acc, xs -> Enum.reduce(xs, acc, ...) end; ... go.(acc, xs) end` → replace `go.(acc, xs)` with `Enum.reduce(xs, acc, ...)`, drop Assign.
- `py_main`: `main = fn -> body end; main.()` → replace `main.()` with `body`, drop Assign.

Files: new module `lib/pylixir/single_use_closure_inline.ex`, plumbed into the ModuleAnalysis → Converter pipeline (run before lowering).

### Item D — Idiomatic chr codegen

`lib/pylixir/builtins.ex:701-702`:
```elixir
def emit("chr", [x], _kw),
  do: {:ok, {{:., [], [{:__aliases__, [], [:List]}, :to_string]}, [], [[x]]}}
```

Replace with bitstring form `<<x::utf8>>`:
```elixir
def emit("chr", [x], _kw),
  do: {:ok, {:<<>>, [], [{:"::", [], [x, {:utf8, [], nil}]}]}}
```

`<<x::utf8>>` and `List.to_string([x])` are semantically equivalent for any valid integer codepoint (both raise `ArgumentError` on out-of-range). Verifiable equivalence.

### Item E — Python annotation passthrough (return + param types)

**Annotation→lattice mapping** (`lib/pylixir/type_infer/annotation.ex`, new):

```elixir
def annotation_to_type(nil), do: :any
def annotation_to_type(%{"_type" => "Name", "id" => "int"}), do: {:int}
def annotation_to_type(%{"_type" => "Name", "id" => "float"}), do: {:float}
def annotation_to_type(%{"_type" => "Name", "id" => "str"}), do: {:str}
def annotation_to_type(%{"_type" => "Name", "id" => "bool"}), do: {:bool}
def annotation_to_type(%{"_type" => "Name", "id" => "list"}), do: {:list, :any}
def annotation_to_type(%{"_type" => "Name", "id" => "tuple"}), do: {:tuple, :any_arity}
def annotation_to_type(%{"_type" => "Name", "id" => "dict"}), do: {:dict, :any, :any}
def annotation_to_type(%{"_type" => "Name", "id" => "set"}), do: {:set}
def annotation_to_type(%{"_type" => "Constant", "value" => nil}), do: {:none}
def annotation_to_type(_), do: :any
```

**Wiring into signature inference** (`lib/pylixir/type_infer/signatures.ex`):

For each `FunctionDef` before the fixpoint runs:
- Read `args.args[i].annotation` for each positional arg → `annotation_to_type/1`
- Read `returns` → `annotation_to_type/1`
- If any non-`:any` value emerged, **pre-seed** `fn_signatures[name]` with `{param_types, return_type}`.

In `compute_round/2` (signatures.ex:62-83), for each function with annotation-derived param_types/return_type: **skip the inference of those slots** and use the seeded values. Recursive callers see the seeded sig from round 1, so fixpoint converges quickly.

Body inference still runs (so e.g. `x` is correctly typed `{:int}` inside `def f(x: int) -> int:`, enabling specialization within the body).

**Const-fold extension for isinstance** (`lib/pylixir/converter.ex:844-863`):

Add a new `const_fold_if_test/1` clause:

```elixir
defp const_fold_if_test(%{
       "_type" => "Call",
       "func" => %{"_type" => "Name", "id" => "isinstance"},
       "args" => [%{"_type" => "Name", "id" => name}, type_ref]
     }, context) do
  case Context.lookup_type(context, name) do
    nil -> :unknown
    :any -> :unknown
    known -> isinstance_constfold(known, type_ref)
  end
end
```

Where `isinstance_constfold/2` returns `{:ok, true}` if `known` is a subtype of `type_ref`'s lattice tag, `{:ok, false}` if disjoint, and `:unknown` otherwise.

Note: this changes `const_fold_if_test/1`'s arity from 1 to 2 (needs context). Touch the call sites in If / IfExp clauses (`converter.ex:792`, `converter.ex:870`).

Result: when user annotates `def succ(x: int) -> int:`, the isinstance test becomes statically true, the existing const-fold path emits only the body branch, and `succ` collapses to `def succ(x), do: 1 + x`.

## Files to modify

- `lib/pylixir/converter.ex` — extend `const_fold_if_test/1` to 2-arity with isinstance clause; route multi-clause def lowering
- `lib/pylixir/nodes/functions.ex` (and/or `lib/pylixir/nodes/lambda.ex`) — multi-clause def emission, unused-param rename
- **NEW** `lib/pylixir/single_use_closure_inline.ex` — generic closure-inlining pass
- `lib/pylixir/converter.ex` — wire the closure-inline pass into the pipeline (between ModuleAnalysis and lowering)
- `lib/pylixir/type_infer/signatures.ex` — pre-seed `fn_signatures` from annotations; respect seeded values in `compute_round`
- **NEW** `lib/pylixir/type_infer/annotation.ex` — `annotation_to_type/1` mapping
- `lib/pylixir/builtins.ex:701-702` — chr emit change

## Expected output

**For `162_church_numerals.py` WITHOUT annotations** (current Python source):
- #3 multi-clause succ: ~5 lines (was 7)
- A `_f` rename: 0 lines, lint-correctness
- B foldl's `go` inlined: -2 lines
- C py_main `main` wrapper inlined: -3 lines
- D chr idiomatic: 0 lines, cleaner
- **Total: ~110 lines** (down from 121)

**For `162_church_numerals.py` WITH annotations** (`intFromChurch(cn) -> int`, `succ(x: int) -> int`):
- All above PLUS:
- `succ` isinstance const-folds, else branch dies, succ becomes `def succ(x), do: 1 + x` (~3 lines)
- `Enum.map(..., &intFromChurch/1)` infers `{:list, {:int}}` via seeded sig → existing `inline_repr_call` fires → py_repr/py_str/py_str_float tree-shake out completely (~34 lines saved)
- **Total: ~65-70 lines**

## Verification

1. **Codegen unit tests** per item:
   - #3: `def succ(x): return 1 + x if isinstance(x, int) else "s"` → assert AST has 2 def clauses with `when is_integer(x) or is_boolean(x)` guard on first
   - A: lambda param with no body ref → emitted as `_<name>`
   - B: `def f(): g = lambda x: x + 1; return g(5)` → `def f(), do: 5 + 1` (post-inline)
   - C: trailing `main = fn -> body end; main.()` → just `body`
   - D: `chr(65)` → `<<65::utf8>>`
   - E annotation: `def f(x: int) -> int: pass` → `fn_signatures[f] = {[{:int}], {:int}}`
   - E const-fold: `def f(x: int): return 1 if isinstance(x, int) else 2` → emits only `1`
2. **Full suite**: `mix test` — every existing test passes unchanged.
3. **Snapshot tests** (or manual diff):
   - `162_church_numerals.py` without annotations → ~110 lines
   - `162b_church_numerals_annotated.py` (new fixture with `-> int` annotations) → ~65-70 lines
   - Both run via `elixir test.exs` and print `[7, 12, 64, 81]`
4. **Regression spot-checks**: 3-4 fixtures with isinstance, nested closures, or lambdas — output unchanged or improved, never broken.

## Implementation order

1. **D** (chr codegen) — 1 line, isolated. Ship first.
2. **A** (underscore unused params) — small, isolated. Ship second.
3. **#3** (multi-clause succ) — moderate, touches Return/IfExp lowering. Independent of E.
4. **E annotation passthrough** (without const-fold) — `annotation.ex` + `signatures.ex` seeding. Enables intFromChurch annotation path.
5. **E const-fold extension** — `const_fold_if_test/2` with isinstance clause. Enables succ annotation path.
6. **B+C** (closure inline pass) — largest, separate module. Ship last to avoid coupling with the above.
