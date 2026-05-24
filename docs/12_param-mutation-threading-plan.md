# Plan: parameter-mutation threading (mutable-aliasing through function calls)

## Context

Python passes mutable objects (lists, dicts, sets) **by reference**: a function
that mutates a parameter is seen by the caller. Pylixir's data model is
immutable — in-place mutations are lowered to *rebinds* of the local variable
(`a[i] = v` → `a = py_setitem(a, i, v)`). That rebind is invisible across a
function-call boundary, so a mutated parameter is **lost** at the call site.

Minimal reproduction:

```python
def f(p):
    p[0] = 99
p = [1, 2]
f(p)
print(p[0])          # CPython: 99 ; Pylixir: 1  ✗
```

This is the root cause of a large slice of the eval corpus's
`output_mismatch` failures (and some timeouts) — most visibly Union-Find /
DSU helpers (`find(u, parent)` does path compression by mutating `parent`),
graph builders (`children[p].append(...)` inside a helper), and any
"fill this list/dict I pass you" idiom. It's the deferred **mutable-aliasing**
limitation noted in the eval analysis.

## Key insight: the machinery already exists for methods

Pylixir already solves the *same* problem for **class methods**. A method that
mutates `self` is detected (`class_mutating_methods/1` →
`method_mutates_self?/1` + `fixpoint_mutating/2`), compiled to return
`{return_value, updated_self}`, and **every call site rebinds the receiver**:

- statement form `obj.m(args)` → `{_, obj} = Class_m(obj, args)`
  (`emit_class_method_rebind/5`, converter.ex:1401)
- assign form `x = obj.m(args)` → `{x, obj} = Class_m(obj, args)`
- expression form `g(obj.m(args))` → `elem(Class_m(obj, args), 0)` — value
  only, mutation dropped (converter.ex:2570-2585)

This plan **generalizes that pattern from "the `self` parameter of methods" to
"any mutated parameter of any function."** Same shape (`{value, p1, p2, …}`),
same call-site-rebind idea, broader analysis.

## Design

### 1. Analysis — which parameters does each function mutate?

New pass (mirrors `class_mutating_methods/1`), producing
`context.fn_mutated_params :: %{fn_name => [param_name]}` (ordered).

A parameter `p` is *mutated* by `f` if `f`'s body contains, with `p` as the
chain root:
- subscript/slice assignment — `p[i] = …`, `p[i][j] = …`, `p[a:b] = …`
- `del p[i]` (incl. nested, per the recent nested-`del` work)
- in-place methods — `p.append/extend/insert/sort/pop/add/update/...`
- augmented subscript assignment — `p[i] += …`
- **transitively**: `f` calls `g(…, p, …)` and `g` mutates the matching
  positional parameter (fixpoint, like `fixpoint_mutating/2`) — this is what
  makes recursive `find(u, parent)` work (its self-call re-threads `parent`).

Reuse the existing root-extraction helpers (`aug_nested_subscript_chain`,
`mutation_receiver_root`, the `subscript_chain_root` added for nested `del`)
and the mutation predicates already in `ModuleAnalysis`/`LoopAnalysis`. Only
**name** parameters are trackable (not destructured/`*args`).

### 2. Codegen — mutating functions return their mutated params

A function `def f(a, b, c)` that mutates `[a, c]` compiles so **every return
path** yields `{orig_return, a, c}`:
- explicit `return e` → `{e, a, c}`
- implicit end-of-body (Python returns `None`) → `{nil, a, c}`
- early returns inside branches/loops — all rewritten.

This is the existing mutating-method return shape (converter.ex:3127,
"mutating method → return `self`") widened to N params. Functions that mutate
**no** params are unchanged (no tuple, no overhead).

### 3. Call sites — rebind the mutated argument variables

For `f(x, y, z)` where `f` mutates params at positions of `x` and `z`:

| call context | lowering |
|---|---|
| statement `f(x,y,z)` | `{_, x, z} = f(x, y, z)` |
| assign `r = f(x,y,z)` | `{r, x, z} = f(x, y, z)` |
| value in a larger expr `g(f(x,y,z))` | `elem(f(x,y,z), 0)` — value only; mutation **dropped** (mirrors the method compromise) |

Only arguments that are **plain names** can be rebound. If a mutated parameter's
argument is a literal/expression/subscript (`f([1,2])`, `f(d["k"])`), there is no
caller binding to update — drop that position from the rebind tuple (the
function still receives and uses it; only write-back is skipped). The
`{…}` pattern uses `_` for non-rebindable / non-mutated positions.

### 4. Boundaries (documented non-goals)

- **True aliasing** — two names bound to the *same* object, mutate via one,
  observe via the other (`b = a; a.append(1); b` ) — still unsupported. That
  needs real reference cells; out of scope. Param-passing is the 95% case.
- **Higher-order / indirect calls** — `fn = f; fn(p)`, `map(f, …)`, storing `f`
  in a list/attr and calling later — can't statically rebind; value-only,
  mutation dropped. (Same limitation methods already have.)
- **Mid-expression mutating calls** — value-only (`elem/2`), as above.
- Mutation through an argument that is itself a function param chains up via
  the transitive analysis (handled), but a *returned* mutated object aliased
  elsewhere is not.

## Touch points

- `lib/pylixir/module_analysis.ex` (or a new `Pylixir.MutationAnalysis`):
  the `fn_mutated_params` fixpoint analysis. Reuse `mutates_name?/2`,
  `subscript_chain_root/1`, `mutation_receiver_root/1`.
- `lib/pylixir/converter.ex`:
  - thread `fn_mutated_params` into `context` (alongside `class_methods`).
  - function-def codegen: rewrite return points to the `{value, …params}` tuple
    (generalize the mutating-method return at ~3127).
  - call-site dispatch for **free-function** calls (`emit_name_call` and the
    hoisted-defp path): emit the rebind tuple — mirror `emit_class_method_rebind/5`
    and the assign/statement/expression handling already written for methods.
- `lib/pylixir/known_function_arities` / hoisting: a function's "signature" now
  includes which params it mutates; ensure hoisted top-level `defp`s and
  `py_main`-local defs agree.

## Verification

1. **Golden fixtures** (CPython oracle) — new `test/fixtures/python/*`:
   - `f(p): p[0]=99` round-trips (the minimal repro).
   - DSU: recursive `find(u, parent)` path compression + `union` → correct
     connectivity counts (the actual `output_mismatch--1` sample).
   - graph builder: `def add_edge(adj, u, v): adj[u].append(v)` in a loop.
   - `del p[i]` / `p.sort()` / `p[i][j]=…` through a parameter.
   - negative controls: passing a literal (`f([1,2])`) — no crash, value correct.
2. **Full suite** — no regressions; pay attention to `slimming_test` (the
   tuple-return adds lines for mutating functions; positive: non-mutating
   functions unchanged) and any test asserting a function's return shape.
3. **Eval delta** — `mix eval.run --limit 200` before/after: expect a chunk of
   `output_mismatch` (and some `elixir_timeout`) move to `ok`.

## Effort & risk

Medium-large. The codegen + call-site work mirrors existing, tested
method-mutation machinery (lower risk), but the **transitive param analysis**
(esp. recursion + cross-function fixpoint) and **getting every return path**
in function bodies are the fiddly parts. Suggest landing in stages:
(a) analysis + single-level (non-transitive) param rebind for statement/assign
calls; (b) transitive + recursion; (c) the expression-position `elem/2`
fallback. Each stage is independently testable and green.
