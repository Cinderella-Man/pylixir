# Plan: parameter-mutation threading (mutable-aliasing through function calls)

## Context — the bug

In Python, lists/dicts/sets are **shared**: hand one to a function, the function
changes it, the caller sees the change.

```python
def fill(box):
    box.append(99)
stuff = [1, 2]
fill(stuff)
print(stuff)          # CPython: [1, 2, 99] ; Pylixir: [1, 2]  ✗
```

Pylixir never mutates in place — `box.append(99)` becomes "make a new list, point
the local `box` at it." That new list lives only inside `fill`; the caller's
`stuff` still points at the old one, so the change is lost at the call boundary.
This is behind a large slice of the eval `output_mismatch` tail (Union-Find,
graph builders, "fill the list I pass you" helpers).

## Approach — A: thread the change back out through the return value

Make a mutating function **return** its updated parameter(s), and make each call
site **swap the caller's variable** to the returned value — i.e. Pylixir rewrites
`fill(stuff)` to the equivalent of `stuff = fill(stuff)` (you still write normal
Python). The change "flows back out" through the return.

This reuses the machinery Pylixir **already has for class methods**: a method that
mutates `self` is detected (`class_mutating_methods` → `method_mutates_self?` +
`fixpoint_mutating`), compiled to return `{return_value, updated_self}`, and every
call site rebinds the receiver (`{_, obj} = Class_m(obj, args)` —
`emit_class_method_rebind/5`). This plan generalizes that from "`self`" to "any
mutated parameter(s)": return `{value, p1, p2, …}`, rebind the argument variables.

### Why A and not "real shared objects" (B)

B = give lists/dicts a real identity in a mutable store (an "object heap" via the
process dictionary or ETS; values become addresses into it). B is the *only* way
to get **all** aliasing correct, but it's a transpiler-wide rewrite of how the two
most common data types are represented, makes **every** list/dict op indirect
through the heap (a real per-operation slowdown that would worsen the timeout
cases), and brings a pile of semantics to get exactly right (copy-makes-a-new-
object, immutable keys, recursive deref, reclamation). **Decision: A, explicitly
as the ceiling.** Pylixir models mutation that flows through *parameters and
returns*, not arbitrary aliasing. B is a separate, much larger project.

## Resolved design decisions (settled by review)

1. **A is the permanent ceiling.** The one thing A can never do: two names bound
   to the *same* object, mutated via one, observed via the other
   (`b = a; fill(a); b…`). Rare in the corpus; documented as unsupported.
2. **Bail when in doubt — never fabricate a value.** A returns "the parameter's
   final value." That's wrong if a function mutates a param *and then re-points*
   it (`p.append(1); p = []` → caller should still see `[…,1]`, not `[]`). So:
   **if a function reassigns a parameter (`p = …`) anywhere, exclude that param
   from threading.** We only ever turn wrong→right or leave wrong→wrong, never
   right→wrong. (Aliasing *inside* a function — `q = p; q.append()` — naturally
   degrades to a safe miss, since we track mutations of `p` by name.)
3. **First pass = top-level named functions only.** Nested functions compile to
   anonymous closures with a self-passing recursion trick and throw-based returns
   (verified); threading through those is dramatically harder. **This means the
   DSU `find(u, parent)` poster child is NOT fixed by the first pass** — it's
   nested + recursive + called in expression position, the hardest combination.
   (Corrects the earlier over-claim that "recursive `find` works.")
4. **Plain-variable arguments only.** `fill(box)` → rebind `box`. Subscript/
   attribute args (`fill(grid[i])`) and literals/expressions (`fill([1,2])`,
   `fill(g(x))`) are *not* rebound in the first pass — literals/expressions
   correctly drop (a temporary); subscript/attr args become a safe miss (write-
   back via the nested-write machinery is a later refinement). Consistent with
   the method machinery's existing `:no_subscript_receiver` bail.
5. **Never thread a function used as a value.** Changing a function's return shape
   only works if we control every call. If the function's name ever appears as a
   value (passed to `map`/`sorted`, stored in a list/dict, returned, aliased),
   leave it entirely alone (normal value-returning shape). Detected by scanning
   for the name outside call position.
6. **Transitive from the start.** A function that mutates a param *indirectly* —
   by passing it to another mutating function — is also threaded (so a wrapper
   like `build(adj)` that calls `add_edge(adj, …)` hands `adj` back to its
   caller). Reuses the `fixpoint_mutating` pattern, tracking which parameter
   flows to which callee parameter, and respecting decisions 2 & 5 (don't
   propagate through a reassigned param or a function used as a value).

## Scope of the first pass (precise)

Thread parameter `p` of a **top-level, always-directly-called** function `f` iff:
- `f` mutates `p` in place — `p[i]=…`, `del p[i]` (incl. nested), `p.append/…`,
  `p[i] += …` — with `p` as the chain root; **or** transitively passes `p` to a
  threaded callee's mutated parameter; **and**
- `f` never reassigns `p` (decision 2); **and**
- `f` is never used as a value (decision 5).

Codegen: such an `f` returns `{orig_return, …threaded_params}` at **every** return
path (explicit `return e` → carry the params in the `{:pylixir_return, …}` throw
payload; implicit end-of-body → `{nil, …params}`). Call sites in **statement** and
**assignment** position rebind plain-variable args (`f(a)` → `{_, a} = f(a)`;
`r = f(a)` → `{r, a} = f(a)`). Functions that thread nothing are unchanged
(no tuple, zero overhead).

## Explicitly deferred (later phases / non-goals)

- Nested + recursive functions (DSU `find`) — needs nested-fn hoisting to named
  functions + recursion-aware threading + expression-position threading.
- Mutating call in expression position (`seen.add(f(p))`, `g(f(a))`) — value-only.
- Subscript/attribute-argument write-back (`f(grid[i])`).
- True aliasing (`b = a`) — permanent non-goal under A.

## Touch points

- `lib/pylixir/module_analysis.ex` (or a new `Pylixir.MutationAnalysis`): the
  `fn_mutated_params :: %{fn_name => [param]}` transitive fixpoint, the reassigned-
  param exclusion, and the used-as-value exclusion. Reuse `mutates_name?/2`,
  `subscript_chain_root/1`, `mutation_receiver_root/1`, `fixpoint_mutating/2`.
- `lib/pylixir/converter.ex`: thread `fn_mutated_params` into `context`; rewrite
  function return paths to the `{value, …params}` tuple (generalize the mutating-
  method return at ~3127, incl. the throw payload); rewrite free-function call
  sites in statement/assign position (mirror `emit_class_method_rebind/5`).
- `known_function_arities` / hoisting: a function's signature now records its
  threaded params so hoisted defps and call sites agree.

## Verification

1. **Golden fixtures** (CPython oracle), `test/fixtures/python/*`:
   - the minimal `fill(box)` round-trip;
   - top-level `add_edge(adj, u, v): adj[u].append(v)` in a loop;
   - a wrapper calling a mutating helper (transitivity);
   - `del p[i]` / `p.sort()` / `p[i][j]=…` through a param;
   - negative controls that must stay correct: passing a literal (`f([1,2])`),
     a function used in `map` (decision 5), a function that reassigns its param
     (decision 2).
2. **Full suite** — no regressions; watch `slimming_test` (tuple-return adds lines
   for *mutating* functions only; non-mutating unchanged) and any return-shape
   assertions.
3. **Eval delta** — `mix eval.run --limit 200` before/after: expect a chunk of
   top-level-helper `output_mismatch` move to `ok`. (DSU-style closures will *not*
   move yet — that's the deferred phase.)

## Effort & risk, staging

Medium. The codegen + call-site rewrite mirrors tested method-mutation machinery
(lower risk); the fiddly parts are the transitive parameter-flow fixpoint and
carrying params through the throw-based returns. Land in stages, each green:
(a) analysis (incl. transitive + both bail rules) + statement/assign rebind for
direct mutators; (b) transitive wrappers end-to-end; (c) — separate, larger —
nested-function hoisting to unlock the DSU class.
