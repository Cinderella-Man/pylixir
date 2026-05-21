# Pylixir example-driven type inference

## Context

Pylixir today emits polymorphic runtime helpers (`py_add`, `py_mult`, `py_int`, `py_input`, `py_alist` wrappers) because `Pylixir.TypeInfer` only knows what syntax reveals — `input()` is always `{:str}`, mutations demote container elements to `:any`, no flow-sensitive narrowing. Eval corpus shows ~15-25% of failures (and most ok-bucket size bloat) are fixable if the transpiler knew concrete runtime types of `input()`-derived names.

The eval harness already has per-sample `%{stdin, expected}` testcase data but discards it at the `Pylixir.transpile(source)` call (`tools/eval/lib/eval.ex:173`). The library should accept that data as optional inference signal — when supplied, types are derived from real execution; when absent, behavior unchanged.

## Locked design decisions

| # | Decision | Picked |
|---|---|---|
| 1 | Inference engine | Trace CPython with `sys.settrace` per example |
| 2 | Stdout role | Post-hoc validation only |
| 3 | Strictness | Trust trace + boundary assertion at input sites |
| 4 | API shape | `Pylixir.transpile(source, examples: [%{stdin, stdout}])` |
| 5 | Trace granularity | Every-line events, ~1MB cap per example |
| 6 | Guard placement | Input boundaries only |
| 7 | Conflict policy | Raise `Pylixir.ExampleConflictError` on type disagreement |
| 8 | Validation API | `Pylixir.validate_transpile(source, examples, runner)` with `runner :: (elixir_source, stdin) -> {:ok, stdout} \| {:error, _}` |
| Q1 | Demote vs trace | Trust trace; `TypeInfer.demote/2` is a no-op for names in `assume_types` |
| Q2 | Trace data flow | Three orthogonal channels: `assume_types`, `fn_signatures`, `boundary_sites` — NOT a single global seed of `ctx.types` |
| Q3 | `bind/3` resolution | **(A′ softened)** trust trace for trace-stable names; on concrete-vs-concrete conflict at `bind/3`, **demote the name** from `assume_types` (fall back to existing inference for downstream binds); existing inference takes over when no `assume_types` entry exists |
| Q4 | Boundary-site detection | **(C)** tree-walk: any RHS expression containing `input()` / `sys.stdin.*` / `sys.argv` marks the LHS Name as a boundary site; type comes from the trace's observation at that lineno |
| Q5 | Trace-stable filter | **(B)** None-aware uniformity: a name is stable iff all non-None observations across all examples agree on a single type `T`. Store as `{:union, [{:none}, T]}` if any None observed, else `T`. Sentinels (`0`, `""`, `[]`) are NOT treated as neutral — only `None` is. |
| Q6 | Scope coverage | **(A)** top-level user `def`s + module-level only. Demoted nested defs, lambdas, comprehensions, methods → trace data dropped silently; existing inference handles. |
| Q7 | Conflict eagerness | **(A — softened at conversion-time)** Cross-example seed-time conflicts raise during `ExampleInference.seed`; mid-conversion `bind/3` conflicts **demote the name** from `assume_types` rather than raise. Seed-time raise still produces `example_conflict--<reason>` harness bucket. |
| Q8 | Harness integration | **(A2)** examples always on; `Eval.PythonCache` extended to store `%{stdout, trace_events}` per `(source, stdin)`. Tracer + preflight collapse into one CPython run per `(source, stdin)`. `--no-examples` opt-out. |
| Q9 | Validation semantics | **(B)** internal `transpile/2`, run every example via `runner`, collect ALL mismatches; return `{:error, [%{idx, expected, actual}, ...]}` or `:ok` |

## Critical files

- `lib/pylixir.ex` — extend `transpile/2`, `to_source/2` with `:examples` opt; add `validate_transpile/3`
- `lib/pylixir/context.ex` — add `:assume_types`, `:boundary_sites` fields
- `lib/pylixir/type_infer.ex` — `bind/3` consults `assume_types` (per Q3 A′); `demote/2` skipped for names in `assume_types` (per Q1)
- `lib/pylixir/type_infer/signatures.ex` — extend `collect_annotated_sigs` to merge example-derived sigs (must enter via annotation path; raw `ctx.fn_signatures` seeds are overwritten by `compute_round`'s `Map.put`)
- `lib/pylixir/converter.ex` — Assign / Call lowering consults `ctx.boundary_sites` at input sites
- `priv/python/serialize.py` — sibling for new `trace.py`
- `tools/eval/lib/eval.ex:173` — harness forwards `examples` (rename `expected → stdout`)
- `tools/eval/lib/eval/python_cache.ex` — extend schema to `%{stdout, trace_events}`
- `tools/eval/lib/eval.ex` `python_outcome` / `run_python_twice` — replace plain CPython invocation with tracer invocation

## New files

- `priv/python/trace.py` — argv `source_path stdin_path out_path`. `exec` source under `sys.settrace` with redirected stdin. Subscribes `call`/`return`/`line`. Per event records `{event, scope, lineno, locals: {name → type_repr}}`. JSON to `out_path` (stdout reserved for user program). Size cap ~1MB, drop further events with `truncated: true` marker. `type_repr`: scalars by name; list/dict/tuple sample ≤8 elements depth-limit-3; sets opaque; generators/files / bytes / range / custom classes → `any`. Uncaught exceptions → exit 0 with `uncaught` populated; partial trace usable.
- `lib/pylixir/example_inference.ex` — `seed(body, examples, ctx, source: String.t()) :: Context.t()`. Reads trace events (from harness cache or fresh tracer invocation depending on caller). Calls `LatticeMap.merge_examples/1`. Applies (A′) trace-stable filter with (B) None-aware uniformity. Raises `ExampleConflictError` on cross-example concrete disagreement. Writes `ctx.assume_types`, `ctx.fn_signatures` (via annotation merge), `ctx.boundary_sites`.
- `lib/pylixir/example_inference/lattice_map.ex` — pure. Tracer JSON → `TypeInfer.t()`. Per-example then cross-example lub via existing `TypeInfer.lub/2`. Conflict detection per Q3 (A′) rules.
- `lib/pylixir/example_inference/boundary_analysis.ex` — AST walk per Q4 (C). Recursive descent over Assign/AnnAssign RHS; any subnode that's a `Name`/`Attribute`/`Call` resolving to `input`, `sys.stdin.read*`, `sys.argv` marks the LHS Name as a boundary site. Returns `%{lineno → {name, observed_type}}`.
- `lib/pylixir/example_inference/boundary_guard.ex` — given a site + type, returns Elixir AST that wraps the parsed value in a `case` raising `Pylixir.BoundaryViolationError` on type mismatch. Container guards check head only (matches tracer's first-element sampling); empty containers pass through.
- `lib/pylixir/errors.ex` — add `ExampleConflictError`, `BoundaryViolationError`.
- `test/pylixir/example_inference_test.exs`
- `test/pylixir/example_inference/lattice_map_test.exs`
- `test/pylixir/example_inference/boundary_analysis_test.exs`
- `test/pylixir/transpile_with_examples_test.exs` — integration: assert emitted Elixir source string-excludes `py_add`/`py_mult`/`py_int` on guarded paths.
- `test/fixtures/python/examples/<NNN>_<slug>.py` + `<NNN>_<slug>.examples.json`

## The three trace-data channels

**`ctx.assume_types :: %{scope_key => %{name => type}}`** — populated by the trace-stable filter (Q3 A′ + Q5 B). Scope key is the bare top-level function name (`"solve"`) or the sentinel `:module` (Q6 A). Consulted by `TypeInfer.bind/3` (use as bind value when syntactic is `:any`/`:bottom`/`{:list, :any}`/etc.; raise on concrete-and-different) and by `TypeInfer.demote/2` (no-op when name is in `assume_types`).

**`ctx.fn_signatures`** — already exists. Extended seeding path: `Signatures.collect_annotated_sigs/1` is modified to merge example-derived signatures alongside source annotations. Example-derived sigs flow through `merge_annotated/2` each round, so they survive `compute_round`'s `Map.put` overwrite that would clobber raw `ctx.fn_signatures` seeds.

**`ctx.boundary_sites :: %{lineno => {name, type}}`** — populated by `BoundaryAnalysis` (Q4 C). Consulted by Converter at Assign / AnnAssign lowering: when the current statement's lineno is in `boundary_sites`, emit the runtime guard wrapping the RHS expression and bind the LHS Name with the boundary's observed type.

## Pipeline integration (`to_source/2`)

```
1. LiteralPropagation.rewrite
2. ModuleAnalysis.analyze
3. Context.new(...)
4. NEW: if examples != [], ctx = ExampleInference.seed(body, examples, ctx, source: src)
        # writes ctx.assume_types, ctx.fn_signatures (annotation-channel), ctx.boundary_sites
        # raises ExampleConflictError on cross-example disagreement (Q7 A)
5. Converter.convert(...) — Module clause invokes TypeInfer.Signatures.infer/3
        # bind/3 now consults assume_types
        # demote/2 now consults assume_types
        # Assign clause consults boundary_sites
        # any bind/3 conflict between syntactic and assume_types raises (Q7 A)
6. Formatter.format
```

## Boundary-guard emission shape

At each site in `ctx.boundary_sites`, Converter wraps the parsed value. For scalar types:

```elixir
n = case py_int(py_input(nil)) do
  v when is_integer(v) -> v
  other -> raise Pylixir.BoundaryViolationError,
    name: "n", expected: :int, observed: other
end
```

For container types (head-check; empty allowed):

```elixir
xs = case Enum.map(...) do
  [h | _] = v when is_integer(h) -> v
  [] -> []
  other -> raise Pylixir.BoundaryViolationError, ...
end
```

After the guard fires, downstream code uses `n` / `xs` with no `py_*` dispatch.

**Tuple-destructure LHS** (`a, b = map(int, input().split())`): no guard emitted. `bind_pattern/3` (`lib/pylixir/type_infer.ex:200`) recurses to Name leaves which call `bind/3` directly; each destructured name still picks up its trace-derived type from `assume_types`. Guard is skipped because there is no single LHS expression to wrap; the type-info benefit lands without runtime checks.

## Validation API (Q9 B)

```elixir
Pylixir.validate_transpile(source, examples, runner) ::
  :ok | {:error, [%{idx, expected, actual, elixir_source}]}
```

Calls `Pylixir.transpile(source, examples: examples)` internally. Iterates ALL examples; collects every mismatch (not just first). `runner :: (elixir_source, stdin) -> {:ok, stdout} | {:error, term}`. Library stays pure — no `Code.eval_string`; caller supplies the runner.

## Cross-function propagation

`Signatures.infer/3` already does interprocedural fixed-point. Once `fn_signatures` is seeded via the annotation path (Q2 channel), nested calls inside `solve()` inherit param/return types and the fixed-point widens through the body. **No new propagation machinery needed.** Q6 (A) restricts coverage to top-level user defs, matching `Signatures.typeable_def?/1`.

## Harness CPython dedup (Q8 A2)

`Eval.PythonCache` today stores per `sha256(source <> "\0" <> stdin)` in `tools/eval/cache/python.jsonl`: `%{"outcome" => "ok", "stdout" => "..."}`. **Schema unchanged.**

A new **side-car cache** `tools/eval/cache/python_traces.jsonl` is introduced, keyed by the same sha256, storing:

```elixir
%{
  "trace_events" => [%{event, scope, lineno, locals}, ...],
  "truncated" => boolean(),
  "uncaught" => nil | %{type, lineno}
}
```

Lookup merges both files: stdout from `python.jsonl`, trace data from `python_traces.jsonl`. Cache hits in `python.jsonl` are NOT invalidated — existing entries serve as before. Trace data is filled in lazily on cache miss.

`Eval.run_python_twice` is updated to: **one tracer run** (`trace.py`, captures stdout + trace_events) + **one plain CPython run** (stdout only). Nondeterminism check is preserved on stdout equality only — trace_events are downstream type info, not a determinism signal. Halves tracer overhead per cache miss vs. running the tracer twice.

`Eval.attempt/2` (line 162) is modified: `Pylixir.transpile(source)` becomes `Pylixir.transpile(source, examples: examples_from_testcases(record))`, where `examples_from_testcases` shapes the per-sample testcases into `%{stdin, stdout}` (renaming the field) and lazily fetches `trace_events` from `PythonCache` per testcase. The library's `ExampleInference.seed/4` accepts pre-computed trace events as an opt to avoid re-running the tracer when the harness already has them.

## Failure modes

| Condition | Behavior |
|---|---|
| `examples: []` | No-op; equivalent to `transpile/1` |
| Tracer crashes (non-zero exit, no JSON) | `Logger.warning`, fall back to no-examples mode for that transpile |
| Tracer JSON has `uncaught` | Use partial trace, mark `ctx.assume_types[:partial?] = true` |
| Tracer wall-clock > timeout (`:trace_timeout_ms`, default 2000) | Kill, drop that example, merge remaining |
| Tracer hits size cap | Use truncated trace, log warning |
| Cross-example concrete disagreement | Raise `Pylixir.ExampleConflictError` during seed (Q7 A) |
| Mid-conversion concrete disagreement (source path examples didn't reach) | `bind/3` **demotes** the name from `assume_types`; downstream binds fall through to existing inference. No raise. |
| Unrepresentable Python type (generator, file handle, bytes, range, custom class) | Map to `:any`; name fails (A′) filter; no raise |
| Boundary guard fires at runtime | Raise `BoundaryViolationError` with name, expected type, observed value |

## Implementation order (8 landable steps)

1. **Accept-and-ignore + Context fields.** `transpile/2`, `to_source/2` opt signatures. `examples` plumbed through but unused. Add `:assume_types`, `:boundary_sites` to `Context`. Test: `transpile(s) == transpile(s, examples: [])` for every existing fixture.
2. **Tracer skeleton.** `priv/python/trace.py` records only top-level `__main__` end-of-program locals. JSON shape locked. Shell-out helper in `ExampleInference`. Manual smoke test from `iex`.
3. **Lattice mapper + (A′)/(B) filter.** `LatticeMap` for scalars, flat list/dict/tuple. None-aware uniformity filter. Unit tests with hand-rolled trace JSON.
4. **Seed `assume_types`; modify `bind/3` and `demote/2`.** Wire `ExampleInference.seed/4` into `to_source/2`. `bind/3` consults `assume_types` per Q3 (A′); raises on concrete disagreement. `demote/2` becomes no-op for names in `assume_types`. Integration test: `n = int(input()); print(n+1)` with example `stdin: "5\n"` emits `+` not `py_add`.
5. **Full tracer events + `fn_signatures` via annotation path.** Add `call`/`return`/`line` events, qualified scope names per Q6 (A), lub-across-examples, conflict detection. Extend `Signatures.collect_annotated_sigs` to merge example-derived sigs. Test nested-fn propagation: `solve(n)` called from `py_main` sees `n: int` inside solve's body.
6. **Boundary analysis (C) + guards.** `BoundaryAnalysis` tree-walk per Q4 (C). `BoundaryGuard` AST emission for scalars + containers (head-check). Converter consults `ctx.boundary_sites` at Assign/AnnAssign lowering sites. Test guards fire with wrong-type stdin.
7. **Failure-mode handling.** Tracer timeout, crash fallback, partial-trace marker, conflict-raise eagerness (Q7 A — seed-time and conversion-time both). Tests per row of the Failure modes table.
8. **Harness integration (A2) + validation hook (Q9 B).** Extend `Eval.PythonCache` schema with `trace_events`. Replace `run_python_twice` with `run_python_with_trace_twice`. Update `Eval.attempt/2` (line 173) to forward `examples`. Add `--no-examples` to `mix eval.run`. Add `example_conflict--*` bucket to `Eval.Bucket`. Add `Pylixir.validate_transpile/3` library function (collect-all semantics). Re-run `mix eval.run --limit 1000` and compare ok-bucket count.

## Out of scope (first iteration)

- Methods inside class defs (Q6 A)
- Lambdas / comprehensions / demoted nested defs (Q6 A)
- Set element types (lattice opaque)
- Recursive structures past depth 3 (tracer cycle handling deferred)
- Parallel tracer runs across examples (serial in v1)
- Generator / iterator narrowing for bare unmaterialized iterators (`nums = map(...)`, then `sum(nums)`)
- Argument-position type variation across calls of the same nested fn (per-call polymorphism — currently lubbed; could later monomorphize)
- Line-anchored types for re-typed names (this plan uses name-keyed `assume_types`; if a name is re-typed mid-function, the trace-stable filter excludes it and existing inference takes over)

**Implicitly in scope (no extra work):**

- **For-loop iter variables** (`for i in range(n):`) — `bind_pattern/3` recurses to the Name leaf which consults `assume_types` via `bind/3`. The tracer observes `i`'s type in the loop body's locals, so `i: int` lands in `assume_types[scope][i]` and the iter binding inherits it. Only requires the loop body to be inside a top-level scope (Q6 A).
- **Tuple destructuring on the LHS** (`a, b = map(int, input().split())`) — same mechanism: `bind_pattern/3` recurses to each Name leaf. Boundary guard is skipped (no single LHS expression to wrap) but `assume_types` is seeded per-name.

## Verification

After step 4: `Pylixir.transpile("n = int(input())\nprint(n + 1)\n", examples: [%{stdin: "5\n", stdout: "6\n"}])` — emitted source contains `+` directly, no `py_add` call.

After step 6: same source with `examples: [%{stdin: "hello\n", stdout: ""}]` — transpile succeeds (trace types `n: str`), emitted source has boundary guard expecting `:str`, downstream `+` becomes `<>`. At runtime with stdin `5\n` the guard does NOT fire (str passes); with non-int input the int-parse fails and the boundary catches it.

After step 7: `transpile(src, examples: [ex_a, ex_b])` where `ex_a` types `n: int`, `ex_b` types `n: str` → raises `ExampleConflictError`. Also: source has unreachable branch `n = "x"`; trace types `n: int`; transpile raises mid-conversion from `bind/3`.

After step 8: `cd tools/eval && mix eval.run --limit 1000` — ok-bucket count is ≥ baseline; `example_conflict--*` bucket visible in `mix eval.hints`; CPython runs deduplicated via cache (verify by deleting `cache/python.jsonl` and re-running, comparing wall-clock to a no-dedup baseline).

Existing test suite (`mix test` from project root) must pass unchanged at every step — no-examples path is a strict subset of existing behavior.

## Remaining open questions

1. **Boundary guard for non-scalar / non-list containers.** Exact AST shape for `{:dict, K, V}`, `{:tuple, [...]}`, `{:set}` guards. Dicts probably check `is_map(v)` + sample one entry; tuples check arity exactly; sets just `is_struct(v, MapSet)`. Recommend deferring concrete shapes to step 6 implementation.
2. **`fn_signatures` merging for recursive functions.** Tracer sees nested frames of the same function. Merge logic must dedupe across frames within a single example before lubbing across examples. Recommend grouping by `(scope, frame_id)` per Python's `id(frame)` and treating each frame as one observation.
3. **bool/int promotion at the lattice boundary.** Lattice keeps `:bool` and `:int` distinct; lub produces a union. Per Q5 strict-uniformity, names observed as both bool and int fall through the (A′) filter naturally. No special handling.
4. **Harness metrics for the new pathway.** `summary.md` could add: samples-with-trace-data, samples-that-conflicted, emitted-source-size delta. Recommend deferring to step 8 implementation; lock the schema only when the numbers are needed.

## Task breakdown

Fine-grained subtasks of the 8 implementation steps. Each subtask = one landable change. Notes inline where current code diverges from plan assumptions.

### Step 1 — Accept-and-ignore plumbing

- **1.1** Add `:assume_types` (`%{}`) and `:boundary_sites` (`%{}`) fields to `Context` struct (`lib/pylixir/context.ex`).
- **1.2** Add `transpile/2` and `to_source/2` accepting `:examples` opt; thread through but ignore.
- **1.3** Regression test: `transpile(s) == transpile(s, examples: [])` across every fixture under `test/fixtures/python/`.

### Step 2 — Tracer skeleton

- **2.1** Create `priv/python/trace.py` with argv `source_path stdin_path out_path`; record end-of-program top-level locals only; emit JSON to `out_path`; lock JSON shape in module docstring.
- **2.2** Add `ExampleInference.run_tracer/2` shell-out helper in `lib/pylixir/example_inference.ex` (no timeout / size-cap yet).
- **2.3** Manual `iex` smoke test confirming JSON shape; commit a fixture file under `test/fixtures/python/examples/` to exercise the helper.

### Step 3 — Lattice mapper + filters

- **3.1** Create `lib/pylixir/example_inference/lattice_map.ex`; scalar-only first (int, float, bool, str, None).
- **3.2** Extend `LatticeMap` to flat list / dict / tuple repr (≤8 elements, depth ≤3) per plan.
- **3.3** Add None-aware uniformity filter (Q5 B) — name stable iff all non-None obs agree.
- **3.4** Cross-example lub via existing `TypeInfer.lub/2`.
- **3.5** Conflict detection (Q3 A′) raising `Pylixir.ExampleConflictError`.
- **3.6** Add `ExampleConflictError` to `lib/pylixir/errors.ex`.
- **3.7** Add `test/pylixir/example_inference/lattice_map_test.exs` with hand-rolled JSON inputs.

### Step 4 — Seed `assume_types`; modify `bind/3` + `demote/2`

- **4.1** Flesh out `lib/pylixir/example_inference.ex` `seed/4`; first cut writes only `ctx.assume_types`.
- **4.2** Modify `TypeInfer.bind/3` to consult `assume_types` (A′ softened): on concrete-vs-concrete conflict between syntactic and trace, **demote the name from `assume_types`** (drop the entry, fall back to existing inference for downstream binds). Do **not** raise. The same modification automatically covers tuple-destructure paths via `bind_pattern/3`'s Name-leaf recursion.
- **4.3** Modify `TypeInfer.demote/2` to no-op when the name appears in `assume_types` (Q1).
- **4.4** Wire `ExampleInference.seed/4` into `Pylixir.to_source/2` between `Context.new` and `Converter.convert`.
- **4.5** Integration test: `n = int(input()); print(n + 1)` with `examples: [%{stdin: "5\n", stdout: "6\n"}]` emits `+`, not `py_add`.

### Step 5 — Full tracer events + `fn_signatures` via annotation path

- **5.1** Extend `priv/python/trace.py` with `call` / `return` / `line` events and qualified scope names per Q6 (A).
- **5.2** Extend `LatticeMap` to derive per-function signatures from frame events; group by `(scope, frame_id)` for recursion (per open Q #2).
- **5.3** Make `Signatures.collect_annotated_sigs/1` **public** (currently private); extend it to merge example-derived sigs alongside source annotations.
- **5.4** `ExampleInference.seed/4` populates `ctx.fn_signatures` via the annotation channel.
- **5.5** Extend cross-example conflict detection to fn signatures.
- **5.6** Test: nested `solve(n)` called from `py_main` inherits `n: int` inside body — no `py_*` dispatch in `solve`'s arithmetic.

### Step 6 — Boundary analysis + guards

- **6.1** Create `lib/pylixir/example_inference/boundary_analysis.ex`; AST walk per Q4 (C) detecting `input`, `sys.stdin.*`, `sys.argv` on RHS.
- **6.2** `ExampleInference.seed/4` populates `ctx.boundary_sites` (`%{lineno => {name, type}}`).
- **6.3** Create `lib/pylixir/example_inference/boundary_guard.ex`; scalar guard emission first.
- **6.4** Extend `BoundaryGuard` with container head-check shape for lists (dict / tuple / set deferred — open Q #1).
- **6.5** Add `BoundaryViolationError` to `lib/pylixir/errors.ex`.
- **6.6** Modify Converter `Assign` clause (entry at `Pylixir.Nodes.Assign.assign/2`) to consult `ctx.boundary_sites`. **Decide here:** add a minimal `AnnAssign` clause (delegating to Assign) or scope guards to bare Assign only — Converter has no `AnnAssign` clause today.
- **6.7** Tests: guard fires on wrong-type stdin, passes on right-type; downstream code uses bare ops.

### Step 7 — Failure modes

- **7.1** Tracer crash (non-zero exit, no JSON) → `Logger.warning` and fall back to no-examples mode for that transpile.
- **7.2** Tracer wall-clock timeout (`:trace_timeout_ms`, default 2000ms) → drop that example, merge remaining.
- **7.3** Tracer size cap (~1MB) with `truncated: true` marker honoured downstream.
- **7.4** Partial-trace marker — set `ctx.assume_types[:partial?] = true` when tracer JSON has `uncaught` populated.
- **7.5** Verify mid-conversion `bind/3` conflict path **softens** correctly: add fixture where an unreachable branch retypes a stable name; assert the name is dropped from `assume_types` and downstream binds fall back to existing inference (no raise).
- **7.6** Tests covering each row of the Failure modes table.

### Step 8 — Harness integration + validation hook

- **8.1** Introduce **side-car cache** `tools/eval/cache/python_traces.jsonl` keyed by the same sha256 as `python.jsonl`. Existing `python.jsonl` schema unchanged. Reader merges both files at lookup time; tracer populates the side-car lazily on cache miss. No invalidation of existing stdout cache.
- **8.2** Replace `Eval.run_python_twice` with **one tracer run** (`priv/python/trace.py`, captures stdout + trace_events) + **one plain CPython run** (stdout only). Compare stdouts for nondeterminism; use trace_events from the tracer run.
- **8.3** Update `Eval.attempt/2` (`tools/eval/lib/eval.ex:173`) to forward `examples`; add `examples_from_testcases/1` helper that shapes testcases into `%{stdin, stdout}` and lazy-fetches `trace_events` from cache.
- **8.4** Add `--no-examples` flag to `mix eval.run`.
- **8.5** Add `example_conflict--*` bucket key to `Eval.Bucket`.
- **8.6** Add `Pylixir.validate_transpile/3` (Q9 B collect-all semantics).
- **8.7** Re-run `cd tools/eval && mix eval.run --limit 1000`; record ok-bucket delta vs baseline in commit / PR.
