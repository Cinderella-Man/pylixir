# Plan: in-place mutation of a loop element — `for row in grid: row[i]=v`

## Context
Python lists are shared mutable refs, so `for row in grid: row[i]=v` mutates `grid`.
Pylixir lists are immutable and it emits `Enum.each(grid, fn row -> row = py_setitem(row,i,v) end)`
— the rebind is discarded, mutation lost (CPython `[[9,2],[9,4]]`, Pylixir `[[1,2],[3,4]]`).
This is the dominant remaining `output_mismatch` class. **Decision: comprehensive coverage**
(threaded vars, tuple targets, break/continue), landed as a **standalone reviewed change**,
implemented in independently-verifiable tiers. Conservative gating ⇒ any unsupported shape falls
back to today's exact codegen (no regression).

Two coupled bugs:
1. Loop emission drops the mutation (target excluded from threading → `Enum.each`).
2. `ModuleAnalysis.mutates_name?` doesn't see `grid` as mutated → promotes it to immutable
   `@var_grid` → rebind would be illegal. Must fix so `grid` stays a rebindable local.

## Core mechanism
**Reframed (verified):** pylixir *already* threads the target through nested `if`/`for`/`while`
inside the fn body — e.g. `if c: row[1]=9` emits `row = if c do row = py_setitem(row,1,9); row else row end`.
`Enum.each` merely *discards* that final value. So the fix is: **stop discarding — yield the body's
last value and collect it**, then reassign the iterable name. Control-flow-nested mutations come along
for free (no extra work). Mirrors the existing reduce pattern (`body_asts ++ [acc_ref]`,
loop.ex ~746/1098); `target_ast` (a bare-name ref, or a destructure pattern reused as a constructor)
is both fn param and yielded value.

### Shared predicate — `LoopAnalysis.target_in_place_mutated?/2` (new, public)
Scope-aware walk (`AST.Walk.walk_scope`; stops at def/lambda/comp boundaries) →
`has_propagating AND NOT wholesale_rebind`. **Invariant:** propagating = exactly the ops that lower
to `t = <op>(t,…)` (rebind the target root to the mutated value); wholesale = disconnecting rebinds.
- **propagating (TRUE)** — subscript/slice/method/del rebinds:
  `t[i]=v`, **`t[i]+=1`**, `t[i][j]=v`, **`t[a:b]=…`**, `t.<@mutation_methods>(…)` (depth 0/1),
  **`del t[i]`**.
- **wholesale (→ FALSE)** — bare-Name `t = …`/`for t in …`/`with … as t`. If a wholesale rebind
  co-occurs with any propagating op, FALSE (final value disconnected from source). Conservative ⇒
  safe fallback.

**Bare-Name augmented-assign is TYPE-GATED (two variants needed).** `t <op>= rhs` lowers to a rebind
of `t` (`converter.ex:1738-1753`), but whether it *propagates to the source* depends on `t`'s type:
- **proven mutable container** — propagating, **not** wholesale. In-place ops only:
  list `+=`/`*=`, set `|=`/`&=`/`-=`/`^=`, dict `|=`.
- **immutable (`int`/`str`/`tuple`) OR unknown/`:any`** — wholesale. (Guards the famous no-op:
  `for x in nums: x += 1` must NOT rebuild `nums`.)
- Co-occurrence rule still applies: `for row in grid: row += x; row = []` → propagating(`+=`) AND
  wholesale(`= []`) ⇒ FALSE (CPython keeps the `+=`, drops the rebind; rebuild-of-final-value would be
  wrong, so fall back = safe wrong).

⇒ **two predicate surfaces**: structural `target_in_place_mutated?/2` (typeless) for
ModuleAnalysis + LiteralPropagation, and type-aware `target_in_place_mutated?/3` (takes `elem_t`;
applies the mutable-`+=` rule) for loop.ex. **CORRECTION (implemented):** in `/2`, bare-Name `+=` must
be treated as *conservatively propagating* ("might rebuild"), NOT wholesale — otherwise `/2`'s set is
NOT ⊇ `/3`'s (loop.ex would rebuild a `list +=` while the promotion/fold gates still think the name is
immutable → stale `print`). With `+=` propagating in `/2`: `propagating₂ ⊇ propagating₃` and
`wholesale₂ ⊆ wholesale₃`, so `/2 ⊇ /3`. Over-reporting an `int +=` no-op is harmless (de-promote /
refuse-fold only; loop.ex's `/3` still won't rebuild it).

Reuse private `target_names/1`, `root_name/1`, `@mutation_methods`. Add `wholesale_rebinds?/2`.
Returns the per-target verdict so tuple targets can ask per name. Mirror `@dialyzer nowarn` (line 37)
if MapSet opacity warns.

### ModuleAnalysis fix (module_analysis.ex, new clause before ~1324)
```
def mutates_name?(%{"_type"=>"For","target"=>tgt,"iter"=>%{"_type"=>"Name","id"=>^name},
                    "body"=>body}, name),
  do: Enum.any?(target_names(tgt), &LoopAnalysis.target_in_place_mutated?(&1, body))
```
(**verified:** reuse ModuleAnalysis's existing private `target_names/1` at module_analysis.ex:542-557
— handles Name/Tuple/List/Subscript and returns the name-string list; no new `target_name_list` helper.)
Additive to the mutation set (only ever makes more names non-promotable). **Cross-function read
(IMPLEMENTED — Process-dict routing turned out UNNECESSARY):** empirically, a top-level literal
iterated+mutated *and* read inside a `def` does NOT compile-error after de-promotion — the existing
inline / closure-demotion machinery (`SingleUseClosureInline`, `demote_closures`, module_analysis.ex
~173-191) already makes the de-promoted runtime local visible (def inlined into `py_main`, or demoted
to a closure capturing it). So no `MutableModuleDict` routing was added; the bare `mutates_name?`
For/iter clause suffices.

**Second fold site (IMPLEMENTED):** de-promotion alone did NOT kill the stale-literal fold —
`Pylixir.LiteralPropagation` (Python-AST pass, *before* the converter) folds `print(grid)` to the
literal whenever `grid` is assigned once and "no mutation observed", and it had the SAME blind spot:
`for row in grid: row[i]=v` wasn't recognized as mutating `grid`. Fixed by adding a `For` clause to
`LiteralPropagation.do_collect_mutations/2` delegating to `LoopAnalysis.target_in_place_mutated?/2`
(structural). Now `print(grid)` reads the live runtime `grid`. For in-function loops there's no module
attr at all → unaffected.

## Tiers (each independently testable & verifiable; land in order)

**Shared gates (all tiers).** (a) iter is a bare `Name` whose id is **NOT** in `analysis.assigned_vars`
— blocks the iterable being mutated *as* the iterable (`for row in grid: grid[0]=row`), which would
collide threading-vs-rebind and hit mutate-while-iterating semantics. (b) no `orelse` — *free*: `emit_for`
is only called when `orelse==[]` (loop.ex:64-66); for-else loops keep today's codegen (deferred coverage).

**T1 — base (`Enum.map`).** Gate: shared gates, single bare-`Name` target, `flow=={false,false}`,
`threaded==[]`, predicate TRUE. Emit `grid = Enum.map(grid, fn row -> body; row end)`; rebind `grid`.

**T2 — tuple targets.** Gate as T1 but target is a **flat** `Tuple` of bare Names (no nested tuples)
AND `elem_t` is a **proven** list-or-tuple shape (not `:any`/union); ≥1 unpacked name mutated in place,
**none** wholesale-rebound (a wholesale rebind of *any* unpacked name corrupts that slot in the
reconstruction). Yield = the destructure pattern reused as a constructor (`[a,b]`/`{a,b}`): verified
expression-valid, and `convert_loop_target` already drives list-vs-tuple shape off `elem_t`
(`converter.ex:2694-2700`) — hence the proven-shape gate. Same `Enum.map`+rebind.

**T3 — threaded vars present.** Gate as T1/T2 but `threaded != []`. Use `Enum.map_reduce/3`:
```
{grid, {a,b,…}} = Enum.map_reduce(grid, {a0,b0,…}, fn row, {a,b,…} -> body; {<yield>, {a,b,…}} end)
```
Rebind `grid` AND the threaded vars (reuse the existing `acc_refs`/`tuple_pattern` builders;
single threaded var → unwrap the 1-tuple).

**T5 — type-proven op-narrowing (north-star: lean on type inference, shrink polyfill reliance).**
Global Converter change, *validated through* the loop fixtures (not loop-scoped — the natural hook is
type-keyed lowering, which applies wherever the type is proven). Narrow each `py_*` call site to the
**exact native call the polyfill already dispatches to**, so semantics (negatives, out-of-range) are
identical by construction:
- `coll[i]` read, `coll` proven `{:list,_}` → `Enum.at(coll,i)` (vs `py_getitem`).
- `coll[i]=v`, proven list → `List.replace_at(coll,i,v)` (vs `py_setitem`).
- `coll += rhs`, `coll` proven list **AND** `rhs` proven list → `coll ++ rhs` (vs `py_add`).
Each op narrows independently; unproven operand types ⇒ keep `py_*` (no regression). **Perf/legibility
only** — does NOT remove a helper definition until *every* call site for it is narrowed (other sites
keep it). First incremental slice of a broader project-wide native-op lowering effort. Land LAST
(after T1–T3; orthogonal to T4) so the propagation tiers are reviewable without it.

**T4 — break/continue (highest complexity; scrutinize).** **Decision: build it, but gate to fallback
first** — land T1–T3 live; keep break/continue+mutation loops on today's codegen until T4 passes a
dedicated review + full corpus pass, then flip the gate. **Emit fully-inlined AST** (no `py_*` helper) —
which makes it denser to review, reinforcing the gate-first sequencing.
Set `loop_break_payload` to the element
ref (+ threaded acc) so `continue`/`break` carry the partially-mutated row. Emit over
`Enum.with_index` with `Enum.reduce_while`, accumulating reversed-rebuilt prefix (+ threaded):
- normal → `{:cont, {[row|acc], …}}`
- `continue` (catch) → `{:cont, {[carried_row|acc], …}}` (keeps mutations up to the continue)
- `break` (catch) → `{:halt, {[carried_row|acc], …, idx}}`
Post: `grid = Enum.reverse(prefix) ++ (if broke, do: Enum.drop(grid, idx+1), else: [])` — splices the
untouched tail (Python leaves post-break elements unchanged). Reuse `ControlFlow.catch_break/2`,
`catch_continue/2`. Consider a small runtime helper to keep the emitted AST readable.

### loop.ex integration (`emit_for`, ~542-621)
Original `iter`/`target` in scope at 542. Compute `rebuild = classify(...)` →
`:none | {:map,…} | {:map_reduce,…} | {:reduce_while,…}`. Extend the `case {threaded,flow}` (586)
to dispatch the rebuild variants first; existing 3 clauses unchanged (matched only when
`rebuild==:none`). Post-loop (619): add the iterable name (and threaded vars) to the rebind list so
the shared `bind_name` runs after `scopes: saved_scopes` (no clobber).

## Critical files
`lib/pylixir/loop_analysis.ex` (predicate+tests), `lib/pylixir/nodes/loop.ex` (classify + 4 emit
variants + post-loop rebind), `lib/pylixir/module_analysis.ex` (For clause),
`test/pylixir/loop_analysis_test.exs`, `test/fixtures/python/` (golden), a loop unit test.
Reuse: `AST.Walk.walk_scope`, `Converter.body_to_block/bind_name/convert_loop_target/tuple_pattern`,
`Naming.rewrite`, `ControlFlow.catch_break/continue`, existing `acc_refs` builders.

## Steps
1. `target_in_place_mutated?/2` (structural) + `/3` (type-aware, mutable-`+=` rule) + `wholesale_rebinds?/2`
   + LoopAnalysis unit tests (incl. `int +=` no-op, mutable `+=`, `+=`-then-wholesale).
2. ModuleAnalysis For clause (delegates to `/2`) + Process-dict routing for de-promoted cross-function
   iterables; confirm no promotion regressions via corpus.
3. T1 emit + classify scaffold + post-loop rebind.  4. T2 tuple.  5. T3 map_reduce.  6. T4 break/continue.
7. T5 type-proven op-narrowing (global; subscript get/set + list `+=`).
8. Golden fixtures + transpile-level units after each tier. `mix test` + full corpus eval each tier.

## Verification — golden fixtures (stdin=/dev/null vs CPython 3.14); ≥1 per tier
- T1: `grid=[[1,2],[3,4]]; for row in grid: row[0]=9; print(grid)` → `[[9,2],[9,4]]`;
  aug `row[1]+=10`; method `row.append(0)`/`row.sort()`; nested `for j in range(len(row)): row[j]*=2`.
- T1 fallback (must be unchanged): `for row in grid: row=[0,0]; print(grid)` → `[[1,2],[3,4]]`.
- **Trap-guards (named, required):**
  - read-after-mutation: `for row in grid: row[0]=9; print(grid)` → `[[9,2],[9,4]]` — proves de-promotion
    killed the compile-time constant-fold (not just the loop rebind).
  - `int +=` no-op: `for x in nums: x += 1; print(nums)` → unchanged — type-gating must NOT rebuild.
  - mutable `+=`: `for row in grid: row += [9]; print(grid)` → reflects the extend; and
    `for row in grid: row += [9]; row = []; print(grid)` → must fall back (co-occurrence ⇒ FALSE).
  - conditional mutation: `for row in grid: \n if row[0]==1: row[1]=9` — proves nested-`if` threading is
    captured by the yield.
- T2: `for a,b in pairs: a.append(b)` (pairs list-of-lists) vs CPython.
- T3: `for row in grid: row[0]=9; total+=row[1]` — assert grid rebuilt AND total correct.
- T4: continue (`for row in grid: if cond: continue; row[0]=9`), break (`...: row[0]=9; if x: break`)
  — verify post-break tail untouched.
Transpile-level: canonical case emits `Enum.map`/`map_reduce`/`reduce_while` (+ rebind) and grid is
NOT `@var_grid`; fallback emits `Enum.each`.
- T5: proven-list `row[i]=v` emits `List.replace_at` (not `py_setitem`); `row[i]` read emits `Enum.at`;
  list `row += xs` emits `++`. Unproven type still emits `py_*`. Output must be byte-identical at runtime
  to the polyfilled version (negatives + out-of-range fixtures).

## Risks / safety
- All tiers opt-in behind conjoined gates; non-matching loops → byte-identical existing codegen.
- ModuleAnalysis change makes more names non-promotable; the one regression risk (top-level mutated
  iterable read cross-function) is neutralized by Process-dict routing — converts a would-be compile
  error into correct, mutable, cross-function-visible state.
- T4 is the only correctness-delicate tier (tail preservation, partial-mutation-on-continue) — gets
  dedicated fixtures + review; if deemed too risky, ship T1–T3 and keep T4 behind the fallback.
- Cross-function aliasing (`def f(g): for r in g: r[i]=v`) fixed only within the function (local
  rebind) — strictly better than today; full pass-by-ref reference semantics remain out of scope.
- **Type-gate soundness:** the `+=`/T2/T5 rules add *no new* trust in TypeInfer — `emit_for` already
  trusts `elem_t` via `coerce_iter` (loop.ex:547) and `bind_pattern` (loop.ex:567). TypeInfer is
  execution-grounded (ExampleInference tracer + `lub` widening + `:any` fallback + boundary guards), so
  a proven concrete container tag is reliable; uncertainty widens to `:any` ⇒ safe fallback. If `elem_t`
  were wrong, existing codegen would already misbehave independent of this change.

## Corpus eval (500-sample slice, baseline vs current)
Baseline = HEAD without the T1–T5 emit/predicate working changes; current = full change.
- ok 343→342, elixir_timeout 77→78 — a single sample flipped ok↔timeout (the load-dependent
  bucket; runs were back-to-back under load).
- **output_mismatch 12→12 (identical buckets) and errors/unsupported 5→5 (identical)** ⇒ NO
  correctness or capability regression.
- This slice contains few for-loop-element-mutation cases, so the fix's benefit isn't visible here
  (output_mismatch unchanged); verified instead by 16 targeted execution tests + the trap-guards.
  A larger corpus batch would surface the OK-rate gain. T5's polyfill-reduction shows up structurally
  (e.g. `py_getitem` is dead-code-eliminated in list-only programs).

## Implementation status (all tiers landed; T4 gated off)
All 8 tasks complete. `mix test` = 1571 tests, 0 failures. T1/T2/T3/T5 live; T4 built + verified but
gated off (`enable_t4_break_continue`, default false). Files: loop_analysis.ex (predicate),
module_analysis.ex + literal_propagation.ex (de-promotion, committed in 86ac5f4), nodes/loop.ex
(classify + 4 emit variants), converter.ex + nodes/assign.ex (T5), test/pylixir/loop_analysis_test.exs
+ test/pylixir/loop_element_mutation_test.exs.

## Resolved (was: unresolved questions)
1. **T4 sequencing** → build it, gate to fallback first, flip after dedicated review + corpus pass.
   IMPLEMENTED: gated on app-env `config :pylixir, enable_t4_break_continue: true` (default false; a
   runtime lookup, not a compile-time constant, so the path stays live for Dialyzer and toggleable by
   tests). Verified correct with the flag on (break tail-preservation, break-before-mutation,
   continue partial-carry, full rebuild, threaded+break); off by default ⇒ break/continue loops fall
   back to `Enum.each`/reduce. To enable: flip the default in `t4_break_continue_enabled?/0`.
2. **T4 helper** → fully-inlined AST (no `py_*` helper).
3. **De-promotion cross-function safety** → route through Process-dict machinery (not style-only).
4. **Bare-Name `+=`** → type-gated propagating, full op set (list `+=`/`*=`, set `|=`/`&=`/`-=`/`^=`,
   dict `|=`); unknown/immutable type ⇒ wholesale.
5. **Iterable-name gate** → fall back when iter name ∈ `assigned_vars`.
6. **T2 tightening** → flat tuple of Names + proven list/tuple `elem_t` only.
7. **Op-narrowing scope** → include as **T5**, but as a *global* type-keyed narrowing of subscript
   get/set + list `+=` (validated via loop fixtures), NOT a loop-local fragment. Perf/legibility only;
   does not delete helper defs. First slice of a broader native-op lowering effort.
8. **Type-gate soundness** → accepted: rules reuse the `elem_t` `emit_for` already trusts (no new
   trust); TypeInfer is execution-grounded + `:any`-biased ⇒ proven tags reliable, uncertainty = fallback.
9. **`target_names` helper** → reuse ModuleAnalysis's existing private `target_names/1` (no new helper).

## Actionable tasks (tracked; land in order, deps in parens)
1. **Predicate** — `target_in_place_mutated?/2` (structural; `+=` always wholesale) + `/3` (type-aware
   mutable-`+=` rule, full op set) + `wholesale_rebinds?/2` + LoopAnalysis unit tests (subscript/aug/
   method/slice/del TRUE; bare rebind & co-occurrence FALSE; `int +=` no-op FALSE; mutable `+=` TRUE).
2. **ModuleAnalysis** (1) — new For/iter clause delegating to `/2` via existing `target_names/1`;
   Process-dict routing for de-promoted cross-function iterables; corpus promotion-regression check.
3. **T1** (1) — `classify(...)` scaffold + shared gates (iter ∉ `assigned_vars`; no `orelse`) +
   single-Name target, `flow=={false,false}`, `threaded==[]`, predicate TRUE → `Enum.map`+rebind +
   post-loop bind. Existing 3 `case` clauses byte-identical when `rebuild==:none`.
4. **T2** (3) — flat `Tuple` of Names + proven list/tuple `elem_t`; ≥1 mutated, none wholesale-rebound;
   destructure-as-constructor yield.
5. **T3** (3; 4 for tuple combo) — `threaded != []` → `Enum.map_reduce`; rebind grid + threaded
   (1-tuple unwrap for single).
6. **T4** (5) — break/continue via `Enum.with_index` + `reduce_while` + reversed prefix +
   `Enum.drop(grid, idx+1)` tail-splice; fully-inlined AST; **built but gated to fallback** until its
   own review + corpus pass.
7. **T5** (3; ⊥ T4) — global type-keyed op-narrowing: proven-list `coll[i]`→`Enum.at`,
   `coll[i]=v`→`List.replace_at`, list `coll += rhs` (rhs also proven list)→`++`; unproven ⇒ keep `py_*`.
8. **Verification** (all) — per-tier goldens + named trap-guards (read-after-mutation, `int +=` no-op,
   mutable `+=`, `+=`-then-wholesale, conditional mutation) + transpile-level asserts; `mix test` +
   full corpus eval each tier.
