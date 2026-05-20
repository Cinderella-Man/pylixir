# Plan: make Python lists fast to index by storing them as Elixir tuples

## The problem in one example

This Python program is 24% of our remaining eval failures. CPython runs it in ~10 ms. Pylixir's transpiled version takes 70+ seconds and gets killed by the 5-second timeout.

```python
x = list(map(int, input().split()))     # 100,000 numbers from stdin
y = list(map(int, input().split()))     # 100,000 more
i = 0
j = 0
while i < len(x) and j < len(y):
    if x[i] < y[j]:                     # ← these reads are O(n) each
        i += 1                          #   100,000 reads × 100,000 walk =
    else:                               #   10 billion cons-cell hops
        j += 1
```

Why it's slow: Python's `list` is an array (O(1) random access). Pylixir lowers it to an Elixir list, which is a linked list. `x[i]` becomes `Enum.at(x, i)` which has to walk `i` cons cells. The inner loop does that ~200,000 times against lists of size ~100,000. That's 10 billion pointer hops.

## The fix in one example

Same Python, but Pylixir notices that `x` and `y` are never mutated after they're created. So it stores them as **Elixir tuples** instead of lists. Reads on Elixir tuples are O(1) (`elem/2`). 10 billion pointer hops → 200,000 single-step lookups → fast.

We wrap the tuple in a tag so the rest of the runtime knows "this came from a Python list, not a Python tuple". The wrap looks like this:

```elixir
# Before:                                          # After:
x = Enum.map(String.split(...), &py_int/1)        x = py_alist_new(Enum.map(...))
                                                  # py_alist_new builds {:py_alist, {1, 2, 3, ...}}
```

A tuple wrapped this way is what we'll call an **alist** (short for "array-list"). It looks like a tuple internally but behaves like a Python list from the outside.

Reading from an alist:

```elixir
def py_getitem({:py_alist, t}, i) when i >= 0 do
  if i < tuple_size(t), do: elem(t, i), else: nil   # O(1)
end
```

## When is the wrap safe?

Only when we can prove the Python list will never be mutated. If the program does `x.append(z)`, we *can't* freeze — `put_elem` on a tuple is O(n), worse than the linked list. We need to scan the Python source before transpiling and only freeze variables that pass a strict "no mutation, no aliases, no sharing" check.

## What counts as "safe to freeze"?

When the program does `x = list(...)`, we look at every other place `x` appears in the same function. If we find any of these, we **don't** freeze:

```python
x = list(map(int, input().split()))

# --- ALL of these disqualify x ---

x.append(5)         # mutating method call
x.pop()             # mutating method call (any of: append, extend, insert, pop,
                    #   popleft, remove, reverse, sort, clear, update, ...)
x[0] = 99           # writing through a subscript
del x[0]            # deleting through a subscript
x = [1, 2, 3]       # reassignment
x += [4]            # augmented assignment

y = x               # aliasing — Python lists are reference-semantics
result = [x, x]     # x inside another container — caller could mutate via result
f(x)                # passing to a user-defined function — callee could mutate
return x            # leaving the function — caller could mutate

# inside a nested function, lambda, comprehension, or class:
def inner():
    print(x[0])     # we conservatively bail even on read-only mention,
                    #   because we can't prove the nested scope won't mutate
```

The uses of `x` that **don't** disqualify it are:

```python
# --- core read shapes ---
x[i]                # indexed read   ← the whole point of freezing
x[a:b]              # slice (also read; returns a fresh regular list)
len(x)              # length
v in x              # membership check ("is v an element of x?")
for v in x: ...     # iteration

# --- read-only builtins (entire allowlist) ---
sum(x)              # also: min(x), max(x), any(x), all(x)
sorted(x)           # also: reversed(x), enumerate(x), zip(x, ...)
list(x)             # makes a fresh regular list copy ← the canonical "copy" form
iter(x)             # also: map(f, x), filter(f, x)
str(x), repr(x)     # formatting
print(x)            # printing (calls str)

# --- read-only methods on x ---
x.index(v)
x.count(v)
x.copy()            # returns a fresh regular list (we ALSO fix Pylixir's
                    #   identity-bug here so this actually copies)
```

Anything outside this set disqualifies the freeze. In particular: `x in y` (passing x to *some other* container's `__contains__` — opposite direction from `v in x`), `f(x)` for any non-allowlisted name `f`, `return x`, `y = x`, `result = [x]`, `x + y`, `x * 2`, and any reference to `x` inside a nested `def`/`lambda`/`class`/comprehension.

The allowlist is curated specifically to be **safe for a frozen alist at runtime**: every builtin and method in it either reads-only or produces a fresh regular list. Anything more permissive risks runtime crashes (e.g. a frozen `x` reaching code that does `x ++ [v]` would blow up — Elixir's `++` can't add a tagged tuple to a list).

## When is the wrap correct?

After freezing, every place that *uses* `x` needs to know how to handle the new representation. Most places already work because Pylixir already routes iterables through a helper called `py_iter_to_list/1` (it converts strings, tuples, ranges, etc. to lists). We just teach `py_iter_to_list` to also unwrap `{:py_alist, t}` (one new function clause).

For *indexed* reads (`x[i]`, `len(x)`, `v in x`, `x[1:5]`), we add a clause for `{:py_alist, t}` to each of these helpers:

| Helper | What it does on an alist |
|---|---|
| `py_getitem({:py_alist, t}, i)` | `elem(t, i)` with a bounds check that returns `nil` for out-of-range (matches existing list behaviour) |
| `py_len({:py_alist, t})` | `tuple_size(t)` |
| `py_in(v, {:py_alist, t})` | `v in Tuple.to_list(t)` |
| `py_slice({:py_alist, t}, ...)` | builds and returns a regular Elixir list (Python slice of a list is a list) |
| `py_iter_to_list({:py_alist, t})` | `Tuple.to_list(t)` |
| `py_str({:py_alist, t})` / `py_repr` | renders `"[1, 2, 3]"` (list-style), NOT `"(1, 2, 3)"` |
| `py_eq` | normalises both sides via `py_iter_to_list` before comparing |

That's the entire helper surface that needs updating: 7-8 helpers, all in `lib/pylixir/runtime_helpers.ex`.

**Important ordering gotcha:** `{:py_alist, t}` is structurally an Elixir tuple. If `py_getitem` already has a `def py_getitem(c, k) when is_tuple(c), do: elem(c, k)` clause, that clause will match `{:py_alist, t}` first and do `elem({:py_alist, t}, 0)` which returns the atom `:py_alist`. The `{:py_alist, _}` clauses MUST come **before** the `is_tuple` clauses. Same gotcha for `py_slice`'s `cond` — needs an `{:py_alist, _}` branch before the `is_tuple` branch.

Mutating helpers (`py_append`, `py_setitem`, `py_pop_at`, `py_delitem`, etc.) are deliberately **not** updated. The safety check above guarantees a frozen alist can never reach them. If our check has a bug and an alist does reach one of these, the program crashes loudly with `FunctionClauseError` — easy to spot, easy to fix.

## How does Pylixir know the value type at compile time?

Pylixir tracks types as it transpiles, so it can emit better Elixir code. Each variable carries a type-tag like `{:list, :int}` (list of ints), `{:tuple, [_, _]}` (a 2-tuple), `{:int}`, etc. The relevant code is in `lib/pylixir/type_infer.ex`.

We add a new type-tag, `{:py_alist, :int}` (or whatever the element type is). When the safety check passes and we wrap a value in `py_alist_new`, we also tell the type tracker "this name now has type `{:py_alist, ...}`".

The key downstream consumer is a helper called `coerce_iter(ast, type)`. It's the choke-point that decides "should I wrap this value in `py_iter_to_list/1` before iterating it?" Today it skips the wrap when the type is `{:list, _}` (because plain lists don't need wrapping). We change it so `{:py_alist, _}` is **not** treated as a list (i.e. it *does* get wrapped). Every iteration consumer in Pylixir — `for`-loops, `sorted`, `reversed`, `min`, `max`, `sum`, `map`, `filter`, list comprehensions — already routes through `coerce_iter`, so they all start handling alists correctly with no further changes.

Concretely, the type-tracker change is about 6 lines:

```elixir
@type t :: ... | {:py_alist, t()}                  # add the variant

def is_list?({:py_alist, _}), do: false            # alist is NOT treated as a list
                                                   # → coerce_iter wraps it
def elem_of({:py_alist, e}), do: e                 # what type are the elements?

def lub({:py_alist, a}, {:py_alist, b}),           # if two alists meet in a phi,
  do: {:py_alist, lub(a, b)}                       # the result is an alist of the
                                                   # combined element type
```

(`lub` is "least upper bound" — when two code paths each bind `x` to a different type, what's the common type that covers both? E.g. `if cond: x = [1, 2]; else: x = [1.0]` → x is a list of `number`. We need an `lub` clause for alists so the type tracker doesn't crash if two alists meet.)

## What does the safety check look like in code?

A new file, `lib/pylixir/alist_analysis.ex`. One public function:

```elixir
@spec freezable_names(body :: [python_ast_node]) :: MapSet.t(String.t())
def freezable_names(body) do
  # 1. Find every `xs = list(<anything>)` assignment.
  # 2. For each `xs`, walk the rest of the body looking for disqualifiers
  #    (mutating method call, reassignment, aliasing, leak into a container,
  #    function-arg passing, return, nested-scope reference).
  # 3. Return the names that survived.
end
```

The implementation reuses existing Pylixir infrastructure:

- `Pylixir.ModuleAnalysis.@mutation_methods` (`lib/pylixir/module_analysis.ex:99`) — the canonical list of mutating method names like `append`, `pop`, `extend`, etc.
- `Pylixir.ModuleAnalysis.mutates_name?/2` (~L1213) — checks a single statement for "is `xs` being mutated here?". Handles `xs.append(...)`, `xs[i] = ...`, `xs = ...`, `xs += ...`, `del xs[i]`, `for xs in ...`.
- `Pylixir.AST.Walk.walk_scope/3` (`lib/pylixir/ast/walk.ex:28`) — walks the function body but **stops** at nested `def`/`lambda`/`class`/comprehension boundaries.

Two new walkers we need to write:

1. **Alias/leak detector**: for each candidate name, walk the body and flag any reference to `xs` other than the four allowed shapes (`xs[i]`, `len(xs)`, `v in xs`, `for v in xs`). Reuses `walk_scope` (same scope rules).

2. **Nested-scope reference detector**: the existing walker stops at nested-scope boundaries by design; we need one that *does* descend, so we can find any mention of `xs` inside a nested def/lambda/comprehension. Just a sibling to `walk_scope` that doesn't stop. If it finds even a read mention, the name bails (we can't prove the closure doesn't mutate).

## Where does the wrap actually get inserted?

Pylixir's converter handles `xs = ...` assignments in `lib/pylixir/nodes/assign.ex`, function `single_target_assign/4`. The Name-target clause (where the left side is a bare variable name) is what we modify:

```elixir
# Pseudocode of the new logic:
defp single_target_assign(%{"_type" => "Name", "id" => name}, value, _node, context) do
  freezable? = name in context.freezable_names and python_calls_list_builtin?(value)

  {value_ast, context} = Converter.convert(value, context)

  emitted_rhs =
    if freezable? do
      # Wrap the value in a call to py_alist_new at runtime.
      {:py_alist_new, [], [value_ast]}
    else
      value_ast
    end

  context =
    context
    |> Converter.bind_name(name)
    |> TypeInfer.bind(name, if(freezable?, do: {:py_alist, elem_t}, else: type_of(value)))

  {{:=, [], [{rewrite(name), [], nil}, emitted_rhs]}, context}
end
```

`python_calls_list_builtin?(value)` is a one-line predicate: "is the Python expression a call to the builtin `list(...)`?". That's the only RHS shape we freeze in the initial cut.

The `context.freezable_names` field gets set when the converter enters a function body, by calling `AlistAnalysis.freezable_names(body)`. It's restored to its previous value when the function exits. The same pattern Pylixir already uses for `context.mutable_module_dicts`.

## Decisions, in plain English

These were resolved during the design grill:

1. **Use a tagged tuple `{:py_alist, t}`, not a bare tuple.** Bare tuples would collide with Python tuples — `str(x)` would print `(1, 2, 3)` instead of `[1, 2, 3]`, and `isinstance(x, list)` would say no.

2. **If `x` is mentioned inside a nested `def`/`lambda`/`class`/comprehension, don't freeze.** Even a read-only mention. Costs some optimisation opportunities, but means we never have to worry about a closure secretly mutating `x`.

3. **The "allowed uses" allowlist** is the full set in the "What counts as safe to freeze?" section above: indexed reads, slice, `len`, `v in x`, iteration, the read-only builtins (`sum`, `min`, `max`, `sorted`, `reversed`, `enumerate`, `zip`, `iter`, `map`, `filter`, `list`, `str`, `repr`, `print`, `any`, `all`), and the read-only methods (`x.index(v)`, `x.count(v)`, `x.copy()`). Everything else disqualifies — including `y = x`, `result = [x]`, `return x`, `f(x)` for non-allowlisted `f`, `x + y`, `x * 2`, `x in y` (opposite direction from `v in x`).

4. **Out-of-bounds `x[100]` on a frozen `x` returns `nil`.** Same as the existing list behaviour (`Enum.at` returns nil for out-of-range). Avoids a behavioural change that could break other Pylixir samples relying on the nil quirk.

5. **Add `{:py_alist, e}` as a real type in Pylixir's type tracker.** Six lines of code; every existing iteration-consuming code path (for-loops, sorted, reversed, etc.) starts handling alists automatically because they all go through `coerce_iter`.

6. **Run the safety check the same way for `def` bodies and module-level code.** Pylixir already wraps module-top statements in a synthetic `py_main()` body — the analysis treats it like any other function.

7. **Only update ~8 helpers** (the ones a frozen value can actually reach). Leave mutating helpers (`py_append`, `py_setitem`, etc.) untouched — they'll crash loudly with `FunctionClauseError` if the safety check has a bug, which is what we want for fast debugging.

8. **Target: `:ok` goes from 76/100 to at least 88/100.** That's recovering ~12 of the 24 timing-out samples. The remaining ~12 are samples that *also* heavily index into append-built secondary lists (`x_sums = []; for n in x: x_sums.append(...)` then `x_sums[i]` in a loop) — those need a follow-up to extend the freeze to comprehensions or detect "append-then-readonly" patterns.

9. **Land everything as one PR.** Helper updates + analysis + emission + type-tracker + tests + golden fixture. If it breaks, revert the one PR.

10. **Two debug knobs ship with it:**
    - `PYLIXIR_DISABLE_ALIST=1` — escape hatch. When set, `AlistAnalysis.freezable_names/1` returns an empty `MapSet` unconditionally, so nothing freezes. Use this to revert to old behaviour without rebuilding.
    - `PYLIXIR_ALIST_DIAG=1` — per-decision logger. When set, every freeze decision emits a structured line: `[alist] f=<function> x=<name> decision=froze` or `[alist] f=<function> x=<name> decision=bailed reason=<reason>`. Lets us see exactly why a variable did or didn't freeze. The eval harness can grep these to summarise gate coverage across the corpus.

## Files we touch

| File | Change |
|---|---|
| `lib/pylixir/runtime_helpers.ex` | New `py_alist_new/1` function. Leading `{:py_alist, _}` clauses on `py_getitem`, `py_len`, `py_in`, `py_iter_to_list`, `py_slice`, `py_str`, `py_repr`, plus a clause in whatever does cross-type equality. |
| `lib/pylixir/type_infer.ex` | New `{:py_alist, e}` type variant. Update `is_list?`, `elem_of`, `lub`. ~6 lines. |
| `lib/pylixir/alist_analysis.ex` | **New file.** `freezable_names/1`. Reuses `ModuleAnalysis.@mutation_methods` + `mutates_name?/2` + `AST.Walk.walk_scope/3`. Honours `PYLIXIR_DISABLE_ALIST=1` (returns empty set). Emits `[alist] …` log lines when `PYLIXIR_ALIST_DIAG=1`. |
| `lib/pylixir/context.ex` | New field `freezable_names :: MapSet.t(String.t())`, default empty. |
| `lib/pylixir/converter.ex` | When entering a `FunctionDef` (and at the start of module-level conversion), call `AlistAnalysis.freezable_names/1` and stash the result in the context. Restore on exit. |
| `lib/pylixir/nodes/assign.ex` | In `single_target_assign/4`'s Name-target clause, wrap the right-hand side in `py_alist_new` when the name is freezable and the RHS is a `list(...)` call. Update the type tracker accordingly. |
| `lib/pylixir/nodes/attribute_methods.ex` | **Concurrent fix.** `do_dispatch("copy", target, [], ...)` currently returns `target` (identity). Change it to `{:py_iter_to_list, [], [target]}` so `x.copy()` produces a real, fresh regular list regardless of whether `target` is a list or a frozen alist. Required for the `.copy()` entry in the allowlist to be safe. |
| `test/pylixir/runtime_helpers_test.exs` | New describe block for `py_alist_*` helpers. Round-trips, O(1) read on a big list, out-of-bounds returns nil, negative indices, equality, `py_str` renders as list. |
| `test/pylixir/alist_analysis_test.exs` | **New file.** Unit tests covering every disqualifier (mutation, aliasing, leak, nested-scope, etc.) plus the happy path. |
| `test/pylixir/nodes/assign_test.exs` | One new test: `xs = list(map(int, ...))` followed only by `len(xs)` and `xs[i]` reads → the emitted Elixir AST contains `py_alist_new(Enum.map(...))`. |
| `test/fixtures/python/189_indexed_read_only_list.py` | **New fixture** mirroring the failing eval pattern (read big list, walk it via `x[i]` in a tight loop, no mutation). Run end-to-end by `golden_corpus_test.exs`. |

## Edge cases at a glance

| Case | What happens |
|---|---|
| `str(x)` / `repr(x)` of frozen `x` | Renders `"[1, 2, 3]"`, not `"(1, 2, 3)"` — `py_str` / `py_repr` have alist clauses that delegate to the existing list-formatting code. |
| `x == y` where one side is frozen, the other a plain list | `py_eq` normalises both sides via `py_iter_to_list` before comparing. |
| `[a, b, c] = x` destructure | Pylixir's loop-1 fix in this branch already routes flat-Name destructures through `py_iter_to_list`. Our new alist clause unwraps. |
| `isinstance(x, list)` on a frozen `x` | Locate Pylixir's isinstance dispatch during implementation; add `{:py_alist, _}` ↔ `list`. |
| `y = x; y.append(z)` | Safety check sees `y = x` (alias of `x`), bails on freezing `x`. No regression. |
| `f(x)` where `f` is user-defined | Safety check bails. |
| `f(x)` where `f` is a builtin like `min`, `sum`, `sorted` | Initial cut: still bails (strict gate). Future enhancement: allowlist of mutation-safe builtins to permit. |
| `x[i] += 1` | Safety check bails (subscript-assign on `x` → counts as mutation). |
| Closure: `xs = list(...); def inner(): xs.append(0)` | Safety check bails (any nested-scope mention of `xs`, even read-only). |
| Out-of-bounds `x[100]` on a 5-element frozen list | Returns `nil`, matching the existing list behaviour. |
| Negative index `x[-1]` | Bounds-checked `elem(t, tuple_size(t) + i)`. Returns `nil` if still out of range. |
| `x[1:5]` slice | Returns a regular Elixir list (Python's "slice of a list is a list"). |
| Iteration `for v in x` | Goes through `coerce_iter` → wraps in `py_iter_to_list` because `is_list?({:py_alist, _}) == false`. |
| `min(x)`, `max(x)`, `sum(x)`, `sorted(x)`, `reversed(x)` | Already coerce via `coerce_iter`. No further work needed. |
| A mutating helper somehow receives a frozen value (safety-check bug) | `FunctionClauseError` — loud failure, easy to debug. We chose this over silently slow fallback. |
| Clause-ordering trap | Every helper's `{:py_alist, _}` clause MUST come before its `is_tuple` clause. Same fix to `py_slice`'s `cond`. |

## How we verify it worked

1. **Full unit suite green.** Run `mix test` in the Pylixir repo. The new `py_alist_*` tests pass; nothing else regresses.

2. **Golden corpus green.** Run `mix test test/pylixir/golden_corpus_test.exs`. This re-runs every fixture in `test/fixtures/python/` through both CPython and Pylixir and diffs their stdout. The new `189_*.py` fixture goes through this gauntlet.

3. **Eval harness: the quantitative target.** From `tools/eval/`:

   ```
   PYLIXIR_PYTHON=python3.14 mix eval.run --limit 100 --samples-per-bucket 5
   ```

   Before this change: `:ok = 76`, `:elixir_timeout = 24`.
   After this change: **`:ok ≥ 88`**, `:elixir_timeout ≤ 12`.

   The remaining ≤ 12 timeouts are samples whose hot loop *also* indexes into an append-built secondary list (something like `x_sums = []; for n in x: x_sums.append(...)` then `x_sums[i]` in a loop). Those need a future follow-up — out of scope here.

4. **No regression at higher sample counts.** Run `mix eval.run --limit 300`. Check that the non-timeout buckets (`python_disagrees_expected`, `output_mismatch`, `elixir_runtime_error`) don't move. Our change is performance-only on the read-only path.

5. **Micro-benchmark.** Add a one-shot timing in `mix eval.probe`: read 100,000 ints into `xs`, then `Enum.reduce(0..99_999, 0, fn i, acc -> acc + py_getitem(xs, i) end)`. Before: tens of seconds (regular list). After: tens of milliseconds (alist). Ratio ≥ 100×.

## Explicitly out of scope

- **Freeze list comprehensions, list literals, `sorted` results.** Initial cut only freezes `list(<iter>)` calls. Expanding the gate is a follow-up once the narrow case is proven.
- **The "append-then-readonly" pattern.** `xs = []; for n in input(): xs.append(...)` then read-only access. The bind site isn't directly freezable (it's `[]`, not `list(...)`); the *tail* of `xs`'s life is read-only but detecting that needs flow-sensitive analysis. Different design.
- **Cross-function freeze.** Passing a frozen list into a user-defined function and have the callee also see it as frozen. Needs whole-program analysis.
- **Thaw on mutation.** Detecting a late mutation of a list that started as `list(<iter>)` and converting back to a regular list right before the mutation. The current gate just bails on mutation. A future enhancement could be smarter.
- **`:array`-based representation instead of tuples.** Discussed and rejected — `:array` has O(log n) reads where tuples have O(1). No upside for our read-only-after-bind workload.

## Phased rollout

Layered bottom-up: runtime primitives → type system → analysis → emission → end-to-end verification. Each phase has a green-tests gate before the next begins. Per decision #9 the whole thing lands as one PR — phases are commit boundaries inside that PR, not separate deliveries. Nothing in P1–P4 changes program behavior on existing fixtures; the feature switches on at P5.

### P0 — `.copy()` dispatch cut-point (independent prerequisite)

- `lib/pylixir/runtime_helpers.ex`: add `def py_copy(x), do: x` (catch-all identity). Lists/maps/MapSets are immutable, so identity is semantically a copy — Pylixir's mutation rewrites rebind the name. The helper exists so P1 can slot in an alist-unwrap clause without retouching the dispatch table.
- `lib/pylixir/nodes/attribute_methods.ex`: change `do_dispatch("copy", target, [], …)` from returning `target` directly to `{:py_copy, [], [target]}`.
- *Deviation note:* the original draft proposed `{:py_iter_to_list, [], [target]}`, but that breaks `d.copy()` (a map → `Map.keys/1`, a list of keys, not a fresh dict) and would silently change set-copy too. A dedicated `py_copy/1` is type-correct for all containers.
- **Gate:** existing suite green; `test/pylixir/runtime_helpers_test.exs` gets a `py_copy/1` describe block covering list, map, and MapSet copies (each: `H.py_copy(x) == x`, then mutate the result and assert the original is unchanged).

### P1 — Runtime alist primitives

- `lib/pylixir/runtime_helpers.ex`:
  - new `py_alist_new/1` (wraps an enumerable as `{:py_alist, List.to_tuple(...)}`);
  - add a leading `{:py_alist, t}` clause to each of: `py_getitem`, `py_len`, `py_in`, `py_iter_to_list`, `py_slice`, `py_str`, `py_repr`, `py_eq`, **and `py_copy`** (cross-type equality normalises via `py_iter_to_list`; the `py_copy` clause unwraps to `Tuple.to_list(t)` so a frozen receiver returns a fresh mutable regular list).
- **Clause-ordering trap:** every alist clause MUST appear before any `is_tuple` clause in the same helper (incl. the `cond` branches inside `py_slice`). Otherwise the catch-all tuple clause swallows the alist and returns garbage.
- Semantics: out-of-bounds `x[i]` returns `nil`; negative indices bounds-checked via `elem(t, tuple_size(t) + i)`; `py_str`/`py_repr` render `"[1, 2, 3]"` not `"(1, 2, 3)"`; `py_slice` returns a regular list.
- **Gate:** new describe block in `test/pylixir/runtime_helpers_test.exs` — round-trips, O(1) read on a 100k-element alist, out-of-bounds → `nil`, negative indices, alist-vs-list equality, `py_str` renders as list. No call sites use these clauses yet, so the rest of the suite stays untouched.

### P2 — Type-tracker variant

- `lib/pylixir/type_infer.ex`: add `{:py_alist, e}` to the `@type t` union; new clauses `is_list?({:py_alist, _}) :: false`, `elem_of({:py_alist, e}) :: e`, `lub({:py_alist, a}, {:py_alist, b}) :: {:py_alist, lub(a, b)}`. ~6 lines.
- The `is_list?` flip is what makes `coerce_iter` wrap alists in `py_iter_to_list` automatically — every iteration consumer (`for`, `sorted`, `reversed`, `min`, `max`, `sum`, `map`, `filter`, list comprehensions) already routes through `coerce_iter`, so they all become alist-aware with no further work.
- **Gate:** unit tests in `test/pylixir/type_infer_test.exs` cover the three new clauses (incl. `lub` of two alists with compatible/incompatible element types).

### P3 — Safety analysis

- **New file** `lib/pylixir/alist_analysis.ex` with public `freezable_names(body, scope_name \\ "(module)") :: MapSet.t(String.t())`. The second arg is used only for diag logging (function name, or `"(module)"` for module-top).
- Reused infrastructure:
  - `Pylixir.ModuleAnalysis.mutates_name?/2` (flipped from `defp` to `def` so the alist analyser can call it) for per-statement mutation detection across every shape — `xs.append(...)`, `xs[i] = ...`, `xs = ...`, `xs += ...`, `del xs[i]`, `for xs in ...`, plus the heapq/bisect mutating-call recognisers.
  - `Pylixir.AST.Walk.walk_scope/3` for candidate discovery and the mutation check (stops at nested-scope boundaries).
- **Three checks** per candidate `xs` (a name bound by `xs = list(...)`):
  1. *Mutation check* — `walk_scope` + `mutates_name?/2` on every node EXCEPT the candidate's own binding (so the initial bind doesn't count as a "reassignment of itself"). A candidate with more than one `list(...)` binding is rejected upstream as a multi-bind reassignment.
  2. *Leak/alias detector* — a slot-aware recursive walker (not `walk_scope`, because legality depends on the parent shape). Allowed: bare `Name(xs)` only inside `Subscript.value`, `For.iter`, `_ in xs` / `_ not in xs` comparator slot, an allowlisted-builtin arg slot, or a read-only-method receiver (`xs.index(v)`, `xs.count(v)`, `xs.copy()`). Stops at scope boundaries (the nested-scope detector covers those).
  3. *Nested-scope mention detector* — sibling that *does* descend into `FunctionDef` / `AsyncFunctionDef` / `Lambda` / `ClassDef` / comprehension bodies. Any mention — even read-only — disqualifies.
- **Debug knobs (this is where they live in code):**
  - `PYLIXIR_DISABLE_ALIST=1` → `freezable_names/2` returns `MapSet.new()` unconditionally (escape hatch, no rebuild required).
  - `PYLIXIR_ALIST_DIAG=1` → emit one structured line per decision to stderr: `[alist] f=<scope> x=<name> decision=froze` or `... decision=bailed reason=<reason>` where reason ∈ `{mutation, leak_or_alias, nested_scope, multiple_list_call_binds}`.
- **Gate:** new file `test/pylixir/alist_analysis_test.exs` — 23 tests covering every disqualifier (mutating method, subscript-assign, reassign, `+=`, alias, container leak, non-allowlisted call, `return`, opposite-direction `in`, arithmetic, nested-scope read, lambda mention), the candidate-shape filter (`xs = [...]` literal doesn't qualify; only `xs = list(...)` does), multi-candidate independence, and the `PYLIXIR_DISABLE_ALIST` knob.

### P4 — Context + converter plumbing

- `lib/pylixir/context.ex`: new field `freezable_names :: MapSet.t(String.t())`, default `MapSet.new()`.
- `lib/pylixir/nodes/functions.ex` `emit_function_def/2`: on body entry, set `freezable_names: AlistAnalysis.freezable_names(body, py_name)`; restore on exit. Mirrors the existing `scopes` / `def_position` / `return_mode` / `types` save/restore pattern. The save/restore also threads through `emit_isinstance_dispatch/13` (new last arg) so the single-clause and dual-clause isinstance lowerings both reset the field correctly.
- `lib/pylixir/converter.ex` `to_source/1`: at module-top, set `freezable_names: AlistAnalysis.freezable_names(runtime_statements)` before converting them; restore after.
- Feature is **still off** at this point: nothing reads `ctx.freezable_names` yet (P5 wires `nodes/assign.ex`). Analysis runs but is inert.
- **Gate:** `mix test` full green (1138 tests, 0 failures — no behavioural change). New `Context.new/1` test asserts `freezable_names == MapSet.new()` by default.

### P5 — Emission (feature switches on here)

- `lib/pylixir/nodes/assign.ex`: in `single_target_assign/4`'s Name-target clause, when `name in ctx.freezable_names` AND `python_calls_list_builtin?(value)` is true, wrap the converted RHS in `{:py_alist_new, [], [value_ast]}`. Bind the name's type to `{:py_alist, elem_t}` in the type tracker (`elem_t` = the list's element type from `TypeInfer.infer_expr`, or `:any` if the type isn't `{:list, _}`); otherwise bind the existing inferred type unchanged.
- `python_calls_list_builtin?/1` is a one-line predicate, kept below the `single_target_assign/4` catch-all so it doesn't split the clause cluster.
- **Gate:** five new tests in `test/pylixir/nodes/assign_test.exs` "alist freeze emission" describe block:
  1. Freezable name with `xs = list(<iter>)` RHS emits `py_alist_new(...)`.
  2. Non-freezable name (later `.append`) does NOT wrap.
  3. List-literal RHS (`xs = [1, 2, 3]`) is not the freezable shape — no wrap.
  4. `PYLIXIR_DISABLE_ALIST=1` suppresses the freeze.
  5. End-to-end run: frozen list reads, lens, sums, sorts correctly.

### P6 — End-to-end verification

- **New fixture** `test/fixtures/python/189_indexed_read_only_list.py` mirroring the failing eval pattern: two `list(...)`-bound variables, two-pointer merge with `x[i]` / `y[j]` reads, plus iteration / `len` / `sum` / `min` / `max` / `sorted` to exercise every helper that picked up an alist clause in P1. Source data is hard-coded (the golden harness runs with `stdin < /dev/null`).
- `mix test` full suite **1144 tests, 0 failures**, incl. `golden_corpus_test.exs` running the new fixture through CPython 3.14 + Pylixir with stdout diff.
- Eval harness (from `tools/eval/`):
  ```
  PYLIXIR_PYTHON=python3.14 mix eval.run --limit 100 --samples-per-bucket 5
  ```
  | Run | `:ok` | `:elixir_timeout` |
  |---|---|---|
  | Baseline (pre-P5) | 76 | 24 |
  | After P0–P6 | **85** | **15** |
  | `PYLIXIR_DISABLE_ALIST=1` re-run | 76 | 24 |
- Hit `:ok = 85`, just under the plan's `:ok ≥ 88` estimate. Delta is +9 :ok / -9 :elixir_timeout. The remaining 15 timeouts include the "append-then-readonly" pattern that the design called out as out-of-scope (`xs = []; for ... xs.append(...); xs[i]`); broadening the freeze gate is the natural follow-up.
- Regression check at `--limit 300`: non-timeout buckets unchanged between alist-on and alist-off (`python_disagrees_expected = 15`, `python_timeout = 8`, `unsupported--Module = 2`, `unsupported--Call = 1`, `output_mismatch = 1`, `elixir_runtime_error--FunctionClauseError = 1`). The single FCE is a pre-existing `defaultdict` lowering quirk, not introduced by this change.
- Micro-benchmark in `mix eval.probe`: deferred — the runtime helper tests already include a 100k-element `py_getitem` correctness loop that completes in milliseconds (would take seconds-to-minutes against a regular list of the same size).

