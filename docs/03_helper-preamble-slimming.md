# Slim runtime-helper preamble for transpile output

## Phase 2 — landed (T6, T7, T8)

Building on S0–S5:

- **T6** — `isinstance` / `callable` / `hasattr` / `issubclass` added to
  `TypeInfer.stdlib_return_type/3` → `{:bool}`. Cascades through S1 elision
  (BoolOp Or of two isinstance calls lubs to `{:bool}`, drops `truthy?`).
- **T8** — Lambda body inference: `infer_expr` recurses through Python AST
  `Lambda` nodes, priming params to `:any` and returning the body's type.
- **T7** — `function_return_type/2` helper + `map(f, xs)` result-type
  refinement using fn_signatures + lambda inference. `list(typed_list)` now
  type-passes-through (was `{:list, :any}` regardless).

Corpus impact:
- avg 4916 → 4880 bytes/fixture (-0.74% additional vs S5-end; -1.0% vs pre-S1)
- church-numerals: 7846 → 7387 (-6%, truthy? family gone)
- isinstance-narrowed slimming fixture: 985 → 526 (-47%)
- new slimming fixtures: `08_isinstance_or.py` 484 bytes; `09_typed_map.py` 5757
- pass rate retained at 998/1000 (99.8%)
- 952 tests, 0 failures

**T7's full impact deferred** — `PR 9`'s fixed-point doesn't yet treat
`map(f, xs)` as a call to `f` with `elem_of(xs)` arg, so user functions
used only via HOF args keep `fn_signatures` return = `:any`. The
infrastructure (`function_return_type/2`) is in place for follow-up.

## Landed state (as of implementation)

S0–S3 and S5 shipped. S4 deferred — full per-clause tree-shaking needs
arg-type propagation through helper-internal calls + stdlib-float-return
tracking that we don't yet have. Will revisit as a follow-up plan.

Corpus-avg byte impact (177 fixtures):
- Pre-S1 baseline: 4929 bytes/fixture, 872,581 total
- After S0–S3+S5: 4916 bytes/fixture, 870,481 total (-0.27% avg)

Slimming-fixture impact (typed-container paths exercised):
- `01_typed_bool_prints.py`: 1203 → 557 (-54%)
- `02_typed_int_list.py`: 3447 → 585 (-83%)
- `03_typed_dict.py`: 3489 → 1062 (-69%)
- `04_nested_containers.py`: 3456 → 859 (-75%)
- `05_isinstance_narrowed_bool.py`: 994 → 985 (-1%)
- `06_repeat_inlined.py`: 3872 → 4028 (+4% — py_repr_str preamble cost)
- `07_polymorphic_fallback.py`: 3417 → 3587 (+5% — same)

The slimming fixtures that exercise the inline paths (01–04) shrink
dramatically. Fixtures that pull py_repr through the polymorphic path
pay ~170 bytes for the inlined py_repr binary clause (Python-correct
quoting) — the cost of the S3 bugfix. The DoD ≥10% corpus-wide target
isn't met without S4; the biggest remaining single bloater is the
~80-line `py_str_float` chain in `runtime_helpers.ex` that S4 would
prune at clause level.

## Context

After PR 1–12 + print/method specialization, fixtures with simple int/str/bool
code emit close to "box standard Elixir." But functional / higher-order code
(e.g. `test/fixtures/python/162_church_numerals.py`) still ships ~200 lines of
helper preamble for ~30 lines of `py_main`. The user's diagnosis: most of the
preamble is dead-code from a tree-shaking-too-coarse standpoint.

Concrete leaks observed on the church-numerals fixture:

| Bloat                                  | Why kept                                                  | Removable? |
|---|---|---|
| `truthy?` family (~30 lines)           | `if truthy?(is_integer(x) \|\| is_boolean(x))` in `succ`  | Yes — `BoolOp` over two `is_X?` returns `{:bool}`; the wrap is unnecessary. |
| `py_str_float` + sci/decimal chain (~80 lines) | Function-level tree-shaking pulls all `py_str` clauses; `is_float` clause references the chain. | Yes (clause-level shake). |
| `py_repr_*` family (~25 lines)         | `py_str` calls `py_repr_list` on lists; `py_repr` calls `py_str` back (cycle). | Partial — inline at user call site when the container is fully typed. |
| `repeat` / `reduce` hoisted defps      | `from itertools import repeat; from functools import reduce` user-imported. | Out of scope — these are user-bound names. |
| `py_bool_to_int`, `py_add`, `py_sub`   | `succ` uses `py_add(1, x)` with `x : :any`. Genuinely polymorphic. | No — leave alone. |

Goal: drop the dead-weight without breaking semantics. Three orthogonal axes,
all four shippable as independent PRs.

## Axis A — `truthy?` elision via TypeInfer (Quick)

`Pylixir.Converter.convert_test/2` at `lib/pylixir/converter.ex:2120` currently
wraps every non-`Compare`-shaped test in `truthy?(...)`. The check delegates to
`Pylixir.AST.BoolReturning.bool_returning?/1` (`lib/pylixir/ast/bool_returning.ex:17-19`)
which only knows the AST shape `Compare → true`.

**Change**: extend the check to *also* consult `TypeInfer.infer_expr/2`. If the
inferred type is **exactly `{:bool}`**, skip the wrap. This catches:

- `BoolOp` of two bool-returning operands (`a or b` where both are `Compare`s
  or `is_X?` calls)
- `Call` to a function whose `fn_signatures` return is `{:bool}` (or stdlib
  return-type table — `isdigit`, `startswith`, etc.)
- `Name` bound to `{:bool}` (e.g., `flag = a == b; if flag: …`)

**Soundness — exact-`{:bool}` only**: unions (even ones containing `{:bool}`,
e.g. `{:union, MapSet([{:bool}, {:int}])}`) keep the `truthy?` wrap. Python's
`0 is falsy / non-zero int is truthy` semantics differ from Elixir's
`only false/nil are falsy`; a bool-int union value could be `0` at runtime,
where Python says "falsy" and Elixir's bare `if 0` says "truthy". Same risk
for `{:any}`. Anything not exactly `{:bool}` stays wrapped.

**Files**:
- `lib/pylixir/converter.ex:2120-2131` — extend `convert_test/2`. Order
  matters: TypeInfer first (handles `BoolOp` / `Call` / `Name` cases the
  existing AST-shape check can't), then the `BoolReturning.bool_returning?/1`
  fast path (handles `Compare` regardless of operand types — even `a < b`
  where one operand is `:any`).

```elixir
case TypeInfer.infer_expr(test_node, context) do
  {:bool} -> test_ast
  _ ->
    if BoolReturning.bool_returning?(test_node) do
      test_ast
    else
      {:truthy?, [], [test_ast]}
    end
end
```

**Win**: drops the entire `truthy?` clause family (~30 lines on the
church-numerals fixture) when no truthy-call survives.

## Axis B — Inline container reprs at the call site (Medium)

`py_str(arg)` on a statically-known container goes through:
`py_str → py_repr_list → py_repr → py_str` (cycle via line 489→594→621 of
`runtime_helpers.ex`). The cycle is why dropping a single clause doesn't help —
all reachable clauses are interlinked through `py_repr`'s catch-all.

### B0 — String-repr quoting fidelity (pre-requisite bug fix)

Existing `py_repr(x) when is_binary(x)` at `runtime_helpers.ex:620` does the
naive `"'" <> x <> "'"`, which diverges from Python for strings containing
single quotes:

- `repr("foo")` → `'foo'` ✓ (current behavior matches)
- `repr("can't")` → expected `"can't"`, actual `'can't'` ✗
- `repr('say "hi"')` → expected `'say "hi"'` ✓ (current behavior matches)

Add a small dedicated helper `py_repr_str/1` to `runtime_helpers.ex` that
implements Python's quote-choice rule:

```elixir
def py_repr_str(s) when is_binary(s) do
  if String.contains?(s, "'") and not String.contains?(s, "\"") do
    "\"" <> s <> "\""
  else
    "'" <> (s |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")) <> "'"
  end
end
```

Update `py_repr(x) when is_binary(x)` to delegate: `do: py_repr_str(x)`. Single
source of truth; both the old polymorphic path and Axis B's inline path use
the same logic.

Scope-creep guard: full Python repr also escapes `\n`/`\t`/non-printable
characters. Out of scope for this fix — `to_string/1` already passes them
through literally, which is what eval-corpus prints expect.

### B1 — Inline list/tuple/dict/set reprs at typed call sites

When the *user call site* has a typed container, emit the formatting inline.
Specifically, in `Pylixir.Builtins.stringify_for_print/1`
(`lib/pylixir/builtins.ex:308`) — add clauses *before* the polymorphic
fallback:

```elixir
# {:list, e} where e is a concrete scalar → inline `Enum.map_join`
defp stringify_for_print({arg, {:list, e}}) when e in [{:str}, {:int}, {:int_lit_nonneg}, {:bool}] do
  formatter = elem_formatter(e)
  body = {{:., [], [{:__aliases__, [], [:Enum]}, :map_join]}, [], [arg, ", ", formatter]}
  {:<>, [], [{:<>, [], ["[", body]}, "]"]}
end
```

`elem_formatter/1` returns the per-element-type capture:
- `{:str}` → `&py_repr_str/1` (the B0 helper — single-source quote logic)
- `{:int}` / `{:int_lit_nonneg}` → `&Integer.to_string/1`
- `{:bool}` → `&py_bool_str/1` (the S2 helper — single-source bool string)
- Nested container (`{:list, e'}` / `{:tuple, ts'}` / `{:set}` / `{:dict, k', v'}`
  where the inner type is also concrete) → **recurse**: build an inline
  formatter `fn x -> <inline_repr_for_e'>(x) end` and pass that. Example:
  `print([[1, 2], [3]])` with type `{:list, {:list, {:int}}}` emits
  ```elixir
  "[" <> Enum.map_join(arg, ", ", fn xs ->
    "[" <> Enum.map_join(xs, ", ", &Integer.to_string/1) <> "]"
  end) <> "]"
  ```
  Falls through to `py_str` only when SOME element slot is `:any`.

Same shape for `{:tuple, ts}` (use `Tuple.to_list` first), `{:set}` (use
`MapSet.to_list`), `{:dict, _, _}` (use `Enum.map_join` with key+value
formatting; both `k` and `v` formatters built recursively from their lattice
types).

Recursion is bounded by the depth of the inferred type, which is bounded by
the source program's structural depth — no risk of unbounded codegen
expansion. For pathological deeply-nested inferred types (`{:list, {:list,
{:list, …}}}`) the inline tree could grow large; cap at depth 3 (return
`:any` formatter beyond that, fall through to `py_str`). Three-deep covers
real-world idioms (matrix of ints, dict of tuples, list of (k, v) pairs from
`.items()`).

This is also the right place to add the **`py_bool_str` helper** the user
requested. Move the inline `if b, do: "True", else: "False"` out of
`stringify_for_print/1`'s `{:bool}` case and into a runtime helper:

```elixir
# runtime_helpers.ex
def py_bool_str(true), do: "True"
def py_bool_str(false), do: "False"
def py_bool_str(x), do: py_str(x)
```

Call sites become `py_bool_str(arg)` — 1-line per print instead of 5.

**Files**:
- `lib/pylixir/builtins.ex:300-325` — add typed-container clauses to
  `stringify_for_print/1`; replace `{:bool}` inline-if with `py_bool_str`.
- `lib/pylixir/runtime_helpers.ex` — add `py_bool_str/1` to the helper block.
- (No `helpers_codegen` changes — the tree-shaker picks up `py_bool_str`
  automatically when referenced.)

**Win**: for fixtures where `print(<typed_container>)` is the sole `py_str`
call site, the entire `py_str` / `py_repr_*` / `py_str_float` chain
tree-shakes out (~100+ lines).

Caveat: when the container's element type is `:any` (e.g.,
`Enum.map(xs, &user_fn/1)` where `user_fn` returns `:any`), the inline path
doesn't fire — falls through to `py_str` as before. Still a net win because
the *typed* call sites stop pulling in the cascade.

## Axis C — Per-clause tree-shaking (Big)

The current `helpers_ast_for/1` (`lib/pylixir/helpers_codegen.ex:192-200`)
keys deps and emission on helper **name**: `@helpers_by_name :: %{name =>
[all_clauses]}`, `@helper_deps :: %{name => [other_name]}`. When `py_str` is
referenced once, ALL ten clauses emit, pulling their full dep closure.

**Change**: track at clause granularity.

1. **Compile-time refactor of `helpers_codegen.ex`**:
   - Tag each clause with `{name, idx, guard_signature}` where
     `guard_signature` is a compact representation of the clause's guards
     (e.g. `[:is_list]`, `[:is_float]`, `[:literal, true]`, `[:catch_all]`).
   - `@helpers_by_clause :: [{key, def_ast}]` instead of `%{name =>
     [def_ast]}`.
   - `@clause_deps :: %{key => [name]}` (per-clause callee set; rewalk each
     clause body individually).

2. **Call-site arg-type tracking — hybrid: AST metadata + sanity assertion**:
   - Primary carrier: store the inferred type on the Elixir AST tuple's
     metadata at emit time: `{:py_str, [type: t], [arg]}`. Elixir AST tuples
     accept arbitrary keyword metadata; `Macro.to_string/1` (Formatter's
     output path) strips it, so it never leaks into the user-visible Elixir.
   - Why safe in current codebase: only two `Macro.prewalk` callers exist
     (`helpers_codegen.ex:143` and `:205`), both read-only — they never
     rebuild the AST tuple. Verified by grepping for `Macro.prewalk`/
     `postwalk`/`traverse` across `lib/pylixir/`.
   - Why hybrid: future AST-rewriting passes might rebuild tuples and lose
     metadata. Belt-and-suspenders: after conversion completes, run a
     `Macro.prewalk` over the emitted ASTs to verify every helper-name
     reference has `type` metadata. Missing metadata → log a warning AND
     default that call site to `:any` (forces all clauses live for that
     helper — sound conservative fallback).
   - Emit helper: introduce a `Pylixir.Converter.emit_helper_call/3` that
     takes `(helper_atom, args, arg_type)` and produces the tagged tuple.
     All `{:py_*, [], [...]}` emit sites in `builtins.ex`, `f_string.ex`,
     `nodes/attribute_methods.ex`, `nodes/compare.ex`, etc. route through
     it — single source of truth for the tagging convention.

3. **Live-clause computation**:
   - For each helper `f`, collect the **set of distinct** arg-types seen
     at call sites: `seen_types[f] :: MapSet.t(TypeInfer.t())`. Each call
     site contributes its arg type as-is — NOT lub'd. Precision matters:
     a fixture with `py_str({:int})` and `py_str({:str})` has
     `seen = MapSet.new([{:int}, {:str}])`, keeping the `is_atom` clause
     dead. Lub'ing to `{:union, …}` would conservatively keep too many
     clauses live (a union admits the catch-all and every guard).
   - For each clause of `f`, compute its **admit-set** `A(c)` — the lattice
     types a value matching the clause could have. Examples:
     - `def py_str(x) when is_list(x)` → `A = {{:list, _}, :any}`
     - `def py_str(x) when is_float(x)` → `A = {{:float}, :any}`
     - `def py_str(x) when is_atom(x)` → `A = {{:bool}, {:none}, :any}` (in
       Elixir, both `true`/`false` and `nil` are atoms)
     - `def py_str(x) when is_map(x) and not is_struct(x)` → `A = {{:dict, _, _}, :any}`
     - Catch-all `def py_str(x)` → `A = top` (admits everything)
   - **Live-rule** (shadow-aware, source order matters):
     ```
     covered = ∅
     for clause c_i in order:
       residual = A(c_i) \ covered
       live(c_i) = seen_types ∩ residual ≠ ∅
       covered = covered ∪ A(c_i)
     ```
     A clause is live only if there's a seen type that *reaches* it (no
     earlier clause already matched that type).
   - **`:any` in seen_types**: forces all clauses live (any one could match
     at runtime). This is the conservative fallback.

3a. **Literal-pattern clauses are always live** (decision: simpler than
    lattice-refining). Clauses like `def py_str(true)`, `def py_str(false)`,
    `def py_str(nil)` don't compute an admit-set; they're emitted whenever
    the parent helper name is referenced. Reasoning: each is 1 line, and
    refining the lattice with literal-tagged subtypes (`{:bool_true}`,
    `{:bool_false}`, `{:none_nil}`) would add machinery whose only payoff is
    deleting ~3 lines per helper. Not worth it.

4. **Recursive call propagation**:
   - When a kept clause body calls another helper, that helper's `seen_types`
     gains the static type the call passes. Repeat until fixed-point.
   - Example: `py_str(x) when is_list(x) → py_repr_list(x)`. If kept, the
     call site `py_repr_list(x)` passes `{:list, _}`. py_repr_list's
     `Enum.map_join(..., &py_repr/1)` passes elements — type
     `elem_of({:list, _}) = _` (the elem type). If concretely `{:int}`,
     py_repr's `is_binary(x)` clause is dead, only the catch-all
     `do: py_str(x)` is live. That py_str call sees `{:int}` — pulls the
     `to_string(x)` catch-all clause, NOT the float chain.

5. **Soundness fallback**: if any tracked type is `:any` and no earlier clause
   in `seen_types`'s intersection rules out the catch-all, emit all
   clauses for that helper. Conservative.

**Files**:
- `lib/pylixir/helpers_codegen.ex` — major rewrite of `@helpers_by_name`,
  `@helper_deps`, `helpers_ast_for/1`, plus new `clause_admits?/2` predicate.
- `lib/pylixir/runtime_helpers.ex` — no changes; clauses must stay contiguous
  (already are; see explore findings).
- `lib/pylixir/converter.ex` — every `{:py_*, [], [...]}` emit site that
  passes typed args annotates the call's metadata with the inferred arg
  type, or alternatively a new emit helper `emit_helper_call/3` records the
  type. Sites: `builtins.ex` (print, str, format, repr), `f_string.ex`,
  the runtime helpers themselves (call-site metadata is harder for
  helper-internal calls — see step 4's recursive propagation).

**Risk**: per-clause guard predicates are easy to get wrong. The fallback is
sound (emit-all on `:any`), but a buggy predicate could mark a clause "dead"
that's actually needed. Mitigation: golden-corpus diff review per shipping
PR — any output diff that isn't strictly a shrink fails CI.

**Win**: drops the `py_str_float` chain (~80 lines) whenever no float reaches
`py_str` statically.

### Bloat-candidate helpers for clause-shaking

S4 builds generic infra (`emit_helper_call/3` + clause-shaking in
`helpers_codegen.ex`); applying it broadly is mostly per-helper book-keeping.
Targets in priority order:

| Helper                  | Dead-clause potential | Notes |
|---|---|---|
| `py_str` family         | High — `is_float` chain, `is_atom` etc. usually never reached when call sites are typed | Primary target. Drops `py_str_float`/`python_sci`/`shift_decimal` chain (~80 LoC) on int/str-only fixtures. |
| `py_add`                | Medium — bool/list/tuple clauses dead when both operands typed as int/str | Saves ~10 LoC per fixture without bool coercion. |
| `py_sub` / `py_mult` / `py_div` / `py_floor_div` / `py_mod` / `py_pow` | Medium — same shape as `py_add` | Routine application of the infra. |
| `py_in`                 | High — set/dict/list/string dispatcher; PR 5 only specializes at typed Compare sites | When fallback `py_in` is included, most clauses are dead. |
| `py_getitem` / `py_setitem` | High — same multi-type dispatch | Dead clauses common after PR 5 Subscript spec covers list/dict. |
| `py_iter_to_list`       | Medium — PR 6 already elides typed sites; the helper's own clauses (string/tuple/map/list) shake by call-site type | Dead when only string-iter sites survived elision. |
| `py_len`                | Low — mostly already inlined by PR 4 at typed sites | Helper still emitted as fallback; clauses prunable. |
| `truthy?`               | N/A — Axis A elides the calls entirely | Once Axis A drops typed-test sites, the residual `truthy?` calls usually all hit the catch-all `_ -> true`; literal clauses (`nil`/`false`/`0`/`""`/`[]`) may be dead. |
| `py_format_value`       | Low — runtime spec parsing makes static specialization hard | Out of scope. |
| `py_bool_to_int`        | Low — 3 trivial clauses, all needed if any bool coercion happens | Out of scope. |

S4 ships the infra first against `py_str` only (proven target). Follow-up
PRs apply it to the next-tier helpers (`py_add`, `py_in`, `py_getitem`).
Each is a small mechanical change: route call sites through
`emit_helper_call/3`, verify behavior on the corpus.

## Phasing

| PR    | Axis | Scope |
|---|---|---|
| S0    | —    | **Prerequisite measurement infra.** Add `mix eval.size` task that emits per-fixture and corpus-average byte counts as CSV (also human-readable summary). Subsequent PRs use it as the gate. Baseline run committed as the "pre-S1" reference. |
| S1    | A    | Truthy? elision via `TypeInfer.infer_expr/2` in `convert_test/2` — exact `{:bool}` only (unions stay wrapped). Existing `BoolReturning.bool_returning?/1` short-circuit kept as fast path. Tests: `if a or b:` where both are bools no longer wraps in `truthy?`; `if x: …` where `x: {:union, …}` keeps the wrap. |
| S2    | B    | `py_bool_str` helper added to `runtime_helpers.ex`. `stringify_for_print/1`'s `{:bool}` branch migrated from inline if/else to `py_bool_str/1` call. Tests: bool prints use `py_bool_str`. |
| S3    | B    | **Folded S2a + S3.** Three changes in one PR: (a) add `py_repr_str/1` to `runtime_helpers.ex` with Python-correct quote choice, (b) redirect `py_repr(x) when is_binary(x)` to delegate to it, (c) add inline-container clauses to `stringify_for_print/1` for `{:list, e}` / `{:tuple, ts}` / `{:set}` / `{:dict, k, v}` when all element slots are concrete. Element formatters reuse `py_repr_str` / `py_bool_str` / `Integer.to_string`. Tests: `print(repr("can't"))` matches CPython's `"can't"`; `print([1, 2, 3])` no longer pulls `py_str` / `py_repr_*`. |
| S4    | C    | Clause-keyed `@helpers_by_clause` + per-clause `@clause_deps` in `helpers_codegen.ex`. Live-clause computation per shadow-aware rule (Axis C step 3). Hybrid metadata: `emit_helper_call/3` routes all helper emits through a tagged tuple; post-conversion sanity walk asserts presence-or-defaults-`:any`. Applied to `py_str` family first; follow-up PRs extend to `py_add`/`py_in`/`py_getitem`/etc. per the bloat-candidate table. Tests: golden-corpus diff review; no behavioral change. |
| S5    | D    | `itertools.repeat` call-site inlining: emit `List.duplicate(x, n)` directly at call sites; drop the `defp repeat` emission. Tests: fixture importing `repeat` no longer ships the wrapper. |

S1–S3 ship one-at-a-time, each with its own measured byte-impact via
`mix eval.size`. S4 is the largest and ships last because S1–S3 may already
remove the call sites that pull dead clauses, lessening S4's marginal yield.

## Verification

```bash
# Per-PR unit tests
mix test test/pylixir/specialization_test.exs

# Full suite must stay green
mix test

# Byte-impact metric (implemented by S0 — gate for every later PR)
mix eval.size

# Manual sanity: the church-numerals fixture
mix eval.show test/fixtures/python/162_church_numerals.py | wc -l
# S1 alone: ~190 lines (was 224 before)
# +S2: ~190 (bool prints absent from this fixture)
# +S3: same — fixture's print uses {:list, :any}, doesn't trigger inline
# +S4: ~110-130 lines (py_str_float chain dropped)

# Bool-heavy fixture
mix eval.show test/fixtures/python/<a-bool-printing-fixture>.py
# Post-S2: bool prints become py_bool_str calls, dropping the inline expansion
```

### Targeted slimming fixtures

Existing `test/fixtures/python/` (177 fixtures) covers stdout-correctness
regression. It does NOT exercise the specific slimming paths this plan
adds — most fixtures are mixed-shape and won't visibly track "did S3 inline
the list repr".

**Add `test/fixtures/slimming/`** as part of S0:

| Fixture                              | Targets | Asserts |
|---|---|---|
| `01_typed_bool_prints.py`            | S1 + S2 | No `truthy?` family; bool prints use `py_bool_str` |
| `02_typed_int_list.py`               | S3      | `print([1, 2, 3])` inlines; no `py_str`/`py_repr_*` |
| `03_typed_dict.py`                   | S3      | `print({"a": 1, "b": 2})` inlines |
| `04_nested_containers.py`            | S3      | `print([[1, 2], [3, 4]])` depth-2 inline |
| `05_isinstance_narrowed_bool.py`     | S1 + PR12 narrow | `if isinstance(x, int): if x == 0 or x == 1:` — no truthy? wrap |
| `06_repeat_inlined.py`               | S5      | `from itertools import repeat` → no `defp repeat` |
| `07_polymorphic_fallback.py`         | negative — S2/S3/S4 | mixed-type call sites; helpers STAY (no false elimination) |

Plus a `mix eval.size --slimming` flag (added in S0) that reports byte
counts for *only* these fixtures in a CSV table. PR review: visual diff of
the table shows exactly which targeted path moved.

Each fixture is 3–10 lines of Python; fixture-corpus growth is negligible.
Subsequent PRs add new fixtures as new paths land (S4 adds
`08_clause_shake_py_str.py` etc.).

### Gates

**Per-PR (every shipping PR in S0–S5)**:
- `mix test` green (full suite).
- `mix eval.size` shows **no byte INCREASE** at the corpus-average level
  (flat is acceptable — PRs that ship inference plumbing without immediate
  spec sites may legitimately be flat).
- 177-fixture stdout-equivalence run stays 100% green (each fixture's
  transpiled output must produce the same stdout as CPython). This is the
  **correctness gate** — catches clause-shaking bugs where a "dead" clause
  was actually live at runtime.

**Whole-plan Definition of Done**:
- Corpus-average transpile size drops by **≥10%** versus the pre-S1
  baseline captured at S0.
- Zero stdout-diff regressions across all 177 fixtures.
- Zero `mix test` failures.
- No eval-bucket regressions (`mix eval.run --skip 1000 --limit 1000 --name
  synthetic_sft` retains current pass rate).

The byte gate is the **optimization-effectiveness** signal; the
stdout-equivalence run is the **soundness** signal. S4 in particular ships
only when both are green — automated, not by eye-over diff review.

## Axis D — Hoisted-import call-site inlining (small)

When a hoisted-import wrapper is a *trivial argument-pass-through* (no
arg-order flip, no inner-fn shuffling), inline at the call site rather
than emit the wrapper defp. Concretely: `itertools.repeat` lowers to
```elixir
defp repeat(elem, times), do: List.duplicate(elem, times)
```
which is a 1-to-1 pass-through. Call sites become
`List.duplicate(<elem>, <times>)` directly; the wrapper defp is never
emitted when all callers are inlined.

**Keep wrapped** (do NOT inline):
- `functools.reduce` — wrapper flips both `(fn, iter, init) → (iter, init,
  fn)` AND inner-fn args `(acc, x) → (x, acc)`. Inlining duplicates the
  inner-fn rewrite at every call site, growing rather than shrinking
  output.
- `itertools.chain` / `accumulate` / `groupby` — each wraps a runtime
  helper (`py_itertools_chain`, etc.), so inlining just rewrites which
  helper name is called; no preamble win.

**Files**:
- `lib/pylixir/converter.ex:998` (`hoisted_defp("itertools", "repeat", ...)`)
  and the call-site lowering. Change the Name-resolution path to emit
  `List.duplicate(x, n)` directly when `repeat` was a hoisted alias.
  Drop the `defp repeat` emission entirely.
- `lib/pylixir/module_analysis.ex` — `hoistable_imports/1` still records
  `repeat` so the name-resolution path knows to inline; just no defp
  emission.

**Win**: ~3 lines per fixture that imports `repeat`. Small but free.

## Out of scope

- `@doc` string compaction (cosmetic; the multi-line @docs are part of the
  source-fidelity contract).
- `py_add` / `py_sub` removal — these need genuine polymorphism in church-
  numeral and similar HOF code; not addressable without deeper type
  inference through function captures. (S4 will prune *clauses* but the
  helper itself stays for polymorphic cases.)
- `functools.reduce` / `itertools.chain`/`accumulate`/`groupby` wrapper
  inlining — see Axis D rationale above.
- `py_format_value` specialization (runtime spec parsing).
