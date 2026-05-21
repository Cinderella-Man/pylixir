# Research: What can pylixir learn from py2many?

## Context

User cloned py2many (Python→Rust/C++/Go/Zig/… transpiler) into the repo and asks:
1. Pick a target language in py2many; mine techniques.
2. Could Python→Rust→Elixir (or Python→Zig→Elixir) help?
3. Could pylixir drop its lattice and get types "for free" from typed conversion?
4. What concrete inference improvements does the comparison suggest?

Deliverable: research report + actionable shortlist.

---

## Headline

**Pylixir's inference is already strictly more sophisticated than py2many's at the framework level.** Wins from comparison are (a) test corpus, (b) pass-separation discipline, (c) ~20 missing stdlib return-type signatures. Indirection through Rust/Zig is a non-starter.

---

## Side-by-side

### Pylixir today (lib/pylixir/type_infer.ex + type_infer/*.ex + example_inference.ex)

- Real lattice — `:any | :bottom | {:int} | {:int_lit_nonneg} | {:float} | {:bool} | {:str} | {:none} | {:list,t} | {:py_alist,t} | {:py_pvec,t} | {:tuple,…} | {:dict,k,v} | {:set} | {:fn,…} | {:union,MapSet.t}` with refinement subtypes.
- Bounded fixed-point pass over user defs (≤5 rounds; recursive calls contribute `:bottom`).
- IsinstanceNarrowing — branch-local narrowing on `if isinstance(x, T):`.
- Static BuiltinSignatures table (~30 entries) for builtin/method return types.
- Example-driven seeding (`priv/python/trace.py` runs program, observes runtime types, populates `ctx.assume_types`).
- BoundaryAnalysis + BoundaryGuard — runtime checks at `input()`/`sys.stdin` sites.
- **Types are OPTIONAL** — `:any` fallback always works; specialisation is purely additive.

### py2many (py2many/py2many/*.py)

- No lattice. Types stored as Python `ast.Name`/`ast.Subscript` nodes on `.annotation` attrs of input AST. Unions are string-templated + reparsed.
- Single-pass walker (`InferTypesTransformer`, inference.py:153-637). No fixed-point.
- Mutability = count assignments per function; >1 → mutable (mutability_transformer.py:15-31). Coarser than pylixir's mutation-scan.
- Scope analysis attaches `.scopes` (ScopeList stack) + `.vars`/`.lhs`/`.mutable_vars` to every node.
- Pipeline (cli.py:44-57) is **explicit, named, ordered**: variable_context → scope_context → assignment_context → list_calls → mutable_vars → nesting → raises → annotation_flags → infer_types → imports. Runs twice (pre/post language-specific rewriters).
- **Types are MANDATORY at emit** — bare `def foo(x):` → Rust `pub fn foo<T0>(x: T0) -> T0`; unbounded T usually fails to compile.
- Rust coverage: 37/67 fixtures = 55%. Many produce `// unsupported`.

### What py2many's Rust transpiler does that pylixir won't

- `str` → `&str` everywhere. Mutation impossible.
- Exceptions → `raise!{…} //unsupported` (invalid Rust).
- Closures over captured vars emit `let f: _ = |x| x + cap` — borrow-checker russian roulette.
- Dict comprehensions, complex slicing, walrus, async, generators: broken or omitted.

---

## Validating each angle the user raised

### A) "Pick a target language"

Pick Rust (most-mature focus per README) or Go (best fixture coverage, 60%). I focused on Rust.

Lesson worth copying: **pipeline-as-explicit-list-of-named-passes** (py2many cli.py:44-57). Pylixir's pre-passes are scattered across `Pylixir.to_source/2`, `Pylixir.Converter`'s Module clause, and `ExampleInference.seed/4`. Naming + ordering them in one place is a doc/maintainability win.

Everything else the Rust transpiler does, pylixir does better.

### B) "Python → Rust → Elixir" — NON-STARTER

Three killers:

1. **Fidelity**: py2many's Rust drops 45% of its own test fixtures + emits `//unsupported` on the constructs pylixir handles best (closures, exceptions, comprehensions, full slicing, walrus).
2. **Rust→Elixir is another transpiler**: comparable scope to pylixir itself. Ownership/lifetimes don't map cleanly back.
3. **Information loss**: `0 is falsy`, `int+float→float`, `list+list=concat` are Python semantics we encode in runtime helpers. After Rust monomorphisation those are gone or mangled.

### B') "Some other typed language (Zig, …)"

Same problems. Any mandatorily-typed target forces lossy decisions (`&str`/`String`, `Vec`/`&[T]`, unbounded `T0`). The only useful indirection target would be typed Python itself.

### B'') "Typed Python as intermediate"

py2many has `--python` target that re-emits Python with inferred annotations added. Pylixir could in principle preprocess with it.

But pylixir's **example-driven inference** is already strictly stronger (runtime trace > syntactic inference) and doesn't require a Python build dep. Skip.

### C) "Don't track types at all"

Two readings:

1. *Drop the lattice, do everything via polymorphic `py_*` helpers.* Works — `:any` fallback already covers this. Cost: emitted Elixir loses readability (`Kernel.+/2` becomes `py_add/2` everywhere; f-strings lose `Integer.to_string` specialisation; iter-consumer sites always wrap in `py_iter_to_list`). Performance regression. Don't.
2. *Drop pylixir's static inference, rely on py2many externally.* Bad — py2many's syntactic inference is strictly weaker than what we have today.

Verdict: keep the design.

---

## What pylixir CAN borrow (ranked by ROI)

### 1. Test corpus from py2many — HIGH value, LOW effort

`py2many/tests/cases/*.py` ships 67 curated fixtures. Cherry-pick the 20-30 that fit pylixir's supported subset (skip `class`, `yield`, user `raise`, `match`):

- `fib.py`, `bubble_sort.py`, `comb_sort.py` — basic algorithms
- `fstring.py`, `walrus.py`, `lambda.py`, `lambda_walrus.py`
- `dict.py`, `dict_comp.py`, `nested_dict.py`, `list.py`
- `with.py`, `with_open.py`, `exceptions.py` (try/except subset only)
- `regex_methods.py`, `stdio.py`, `print.py`
- `built_ins.py`, `comparison.py`, `equations.py`, `arithmetic.py`
- `byte_literals.py`, `loop.py`, `ifexp.py`, `gen_exp.py`

Add under `test/fixtures/python/`. Run via existing `Pylixir.GoldenCorpusTest`. Bonus: when py2many's Rust *and* pylixir's Elixir both run the fixture and stdouts agree → cross-implementation cross-check.

### 2. Pipeline-as-explicit-passes — MEDIUM value, LOW effort

Extract `Pylixir.Pipeline` module owning the ordered pre-pass list as data:

```elixir
@passes [
  {:module_analysis, &ModuleAnalysis.analyze/1},
  {:signatures,      &TypeInfer.Signatures.infer/3},
  {:example_seed,    &ExampleInference.seed/4},
  {:boundary,        &BoundaryAnalysis.analyze/1},
  # …
]
```

Per-pass tests trivial. Order is one read. New pass = one entry.

Refactor, no behaviour change.

### 3. Missing builtin/stdlib return-type signatures — MEDIUM value, LOW effort

Audit py2many's stdlib mappings (`py2many/inference.py:21-44` + `pyrs/plugins.py` + per-language `plugins.py`). Diff against `Pylixir.TypeInfer.BuiltinSignatures`. Likely additions:

- `random.choice(xs)` → `elem_of(xs)`
- `random.randint(a,b)` → `{:int}`
- `os.path.join(...)` → `{:str}`
- More `str.*` methods missing return shapes
- `dict.get(k, default)` → `lub(v, type_of(default))`
- `dict.setdefault` → `v`
- `list.pop`, `list.index`, `list.count`
- `enumerate`, `zip`, `reversed`, `sorted` return shapes (some present, audit completeness)

Each missing entry → one clause in BuiltinSignatures. Cheap.

### 4. Extend truthy-drop to `{:str}` and `{:list,_}` — LOW value, LOW effort

`Pylixir.Converter.convert_test/2` currently drops the `truthy?/1` wrap only when TypeInfer says `{:bool}`. Extend:

- `{:str}` → emit `s != ""`
- `{:list, _}` → emit `s != []`
- `{:dict, _, _}` → emit `map_size(d) > 0` (only if statically known non-alist)
- `{:int}` → emit `n != 0`

Eliminates a `py_*` call per `if x:` where type is known. Readability polish; perf nothing.

### 5. Add explicit `:lhs` flag to Name conversions — LOW value, MEDIUM effort

py2many's `add_assignment_context` marks assignment targets with `.lhs = True`. Pylixir's destructure code (`nodes/assign.ex`) implicitly knows this via dispatch path. Adding an explicit flag would simplify the destructure zoo. Worth it only if `nodes/assign.ex` needs another major change.

---

## What NOT to copy

- **AST-node-mutation symbol tables** (py2many attaches `.scopes`/`.vars`/`.annotation` to input AST). Pylixir threads via immutable Context — cleaner, re-entrant, no spooky action.
- **Single-pass walker w/o fixed-point**. We need the fixed-point for mutual recursion. py2many skips it because Rust's compiler catches divergence — we have no such net.
- **Mandatory-types posture**. Pylixir's "specialise when known, polymorphic helper otherwise" is the right design for an Elixir target.

---

## Recommended action plan

Personal-project execution → 4 commits, no PR series. Refactor-first order **2 → 1 → 3 → 4**: pure refactor first against the smallest stable corpus (191 existing fixtures), then expand the corpus, then ship the behaviour-changing items against the larger safety net.

### Commit 1 — Extract `Pylixir.Pipeline` (wide scope, pre-passes only)

- New module `Pylixir.Pipeline` with `run(body, examples, source) :: %{body, context, analysis}`. Single entry point.
- `@passes` is internal data, **heterogeneous signatures** (no uniform envelope): each entry declares `input_keys` + `output_key` over a state map. Adding a pass = one line; pass dependencies are explicit.
- Six entries, **order must match current execution exactly**:
  1. `LiteralPropagation.rewrite/1`
  2. `ModuleAnalysis.analyze/1`
  3. `ExampleInference.seed/4` (encapsulates `BoundaryAnalysis.analyze/1` — not a top-level entry)
  4. `TypeInfer.module_summary/2`     ← lifted out of `Converter.convert(Module)`
  5. `TypeInfer.seed_module_attr_types/2`  ← moved from private `converter.ex:3035` to public `TypeInfer`
  6. `TypeInfer.Signatures.infer/3`   ← lifted out of `Converter.convert(Module)`
- Scoped passes (`AlistAnalysis`, `PvecAnalysis`, `AppendBuildAnalysis`) **stay inside the Module clause** — they configure context state for a specific conversion subsection, not module-global pre-passes. Lifting them would leak conversion's scope semantics into Pipeline.
- `to_source/2` becomes: `Pipeline.run` → `Converter.convert` → `Formatter.format`.

### Commit 2 — Gap-analysis-driven fixtures (not py2many's cherry-pick list)

- Skip the named cherry-pick list. With 191 existing fixtures, `fib`/`walrus`/`byte_literals`/`fstring`/`print` are all dupes; adding them inflates the corpus without adding signal.
- Gap analysis is itself a discrete sub-task: enumerate existing fixtures by category (algorithm, data structure ops, control flow, stdlib usage, string ops, …), identify 5-10 *categorical* gaps, then steal algorithm shapes from py2many to fill them.
- **Rewrite-and-adapt, no attribution.** We're stealing algorithm ideas, not code: every fixture goes through pylixir's own example-driven test-data shape, and the actual Python is regenerated rather than preserved. py2many is MIT-licensed; attribution would be ceremonial since no copied artifact remains.
- Likely categorical gaps after sampling: sort algorithm, dict comprehension, generator expression, nested-dict mutation, context manager with file. Net add: 5-15 fixtures, not 20-30.
- Verify: each new fixture passes `GoldenCorpusTest` (CPython stdout == pylixir-transpiled stdout, formatter-idempotent).

### Commit 3 — Extend `BuiltinSignatures` (return-types only)

- Scope: return-types for calls pylixir's converter **already supports**. Adding a signature for a call the converter can't emit produces dead code.
- Audit methodology: read py2many's stdlib mappings → produce candidate list → for each candidate, grep `lib/pylixir/stdlib/` + `lib/pylixir/converter.ex` to verify converter support → add `BuiltinSignatures` clause iff supported.
- Coverage expansion (new `stdlib/random.ex`, `stdlib/os.ex`) is **out of scope** — it's emitter design + runtime helpers + Elixir semantics, a different kind of work. Note dead-signature candidates for future converter work; skip them here.
- Expected wins inside already-supported surface: flow-sensitive `dict.get(k, default)` / `dict.setdefault(k, default)` / `dict.pop(k, default)` returning `lub(value_type, type_of(default))`; `list.pop()` returning element type; verification of `math.gcd`/`lcm`/`prod`, `re.match`/`search`, `itertools.*` element-type propagation against existing `stdlib/` modules.
- Tests: unit-test new clauses in `test/pylixir/type_infer_test.exs`.

### Commit 4 — Extend `convert_test/2` truthy-drop (no dict)

- Types in scope: `{:str}`, `{:list,_}`, `{:int}`, `{:float}`, `{:tuple,_}`, `{:set}`, `{:bytes}`. **`{:dict,_,_}` deferred** — alist optimisation means some dicts emit as keyword lists; `map_size/1` blows up on keyword lists. The alist-aware emit dispatch is its own decision.
- **Symmetric**: `convert_test/2` handles positive form (`if x:` → `if x != "":`); the UnaryOp `not` handler at `converter.ex:1487` handles negated form (`if not x:` → `if x == "":`). Each typed case = two parallel emit rules, positive `!=` and negative `==`.
- Tests: assert no `truthy?(s)` wrap in emitted source for typed sites; add cases to `test/pylixir/converter_test.exs`.

### Cross-cutting verification

- **Golden corpus is semantic, not syntactic.** `GoldenCorpusTest` runs each fixture through CPython AND pylixir, compares stdouts. It catches *behaviour* changes; it does NOT catch syntactic drift in generated Elixir that happens to preserve stdout. Implication for Commit 1: Pipeline's pre-pass order must match current execution exactly — a reordering that preserves stdouts on all 191 fixtures could still silently change generated source elsewhere.
- Commit 1 expected diff: zero behavioural change → `mix test` green identically before/after.
- Commits 3 and 4 will update goldens (specialised emit shapes); commit them with the source change.

---

## Indirection — revisited

Python → typed intermediate → Elixir was canvassed (Rust, Zig, "typed Python"). All non-starters per the side-by-side above. One refinement worth recording for honesty:

**mypyc ≠ mypy.** mypyc is mypy's Python→C compiler and *does* require annotations to compile efficiently. **mypy itself** is the type checker and *does* perform type-inference on un-annotated code — that is most of what mypy does daily. Tools like `MonkeyType` / `PyAnnotate` re-emit annotated Python from runtime traces, similar in spirit to pylixir's `ExampleInference`.

So the indirection worth evaluating is **"run mypy as a preprocessing step, harvest its inferred types into `ctx.assume_types`"**, not "Python → mypyc → Elixir."

Verdict still skip: heavyweight Python dep, mypy's internal API is unstable, and `ExampleInference` (runtime tracing) is already strictly stronger than static inference for the example-driven case. But the rejection is *for the right reasons*, not because mypyc requires annotations (it does; but mypy doesn't, and the original framing conflated the two).
