# Static type inference + monomorphization

## Context

Every `+` / `*` / `len` / `in` / `x[k]` in user code currently lowers to a
polymorphic runtime helper (`py_add`, `py_mult`, `py_len`, `py_in`,
`py_getitem`) that dispatches on argument type at runtime via guards.
These helpers are *the* biggest source of bloat in the generated
`TranslatedCode` — `py_mult` alone is 37 lines / 14 clauses, `py_add` 16
lines / 7 clauses. Tree-shaking already drops helpers nobody calls; the
next opportunity is to never emit the call in the first place when the
type is statically knowable.

User framing: "trace types from `__main__`". Premise needs a correction
that doesn't change the strategy: only ~41% of synthetic_sft and ~0.6%
of fixture samples have `if __name__ == "__main__":`. But `py_main`'s
body is *always* the entry — `def main()` versus free-floating
top-level is a source-shape difference, not a flow-analysis difference.
Inference runs over the same root either way.

Behaviour contract — `Pylixir.transpile/1` stdout must remain
bit-identical to today. The pass is purely additive: when a type is
unknown the existing polymorphic helper is emitted, unchanged.

## Decisions log

Recorded resolutions for design ambiguities found during grilling.
Each is referenced in-place below by the Q-tag.

| Tag   | Topic | Resolution |
|---|---|---|
| Q1-B  | Dict-value subscript reads | Always return `:any` — keeps `py_add(nil, n) = n` defaultdict idiom intact. |
| Q2-B  | `*` on `str`/`list` × `int` | Specialize only when the int operand is a literal `Constant >= 0`. Dynamic ints fall through to `py_mult`. |
| Q3-C  | Inter-procedural reach | Bounded fixed-point iteration over `module_summary/1` — caller arg types and recursive return types both refine until `fn_signatures` is stable (capped at 5 iterations; conservative `:any` fallback if not converged). |
| Q5-C  | Subscript-Assign / mutation element widening | Container element types frozen on init from literal; demoted to `:any` on any mutating site. |
| Q6-A  | Tuple destructure / multi-target Assign | Recursive `bind_pattern/3` mirroring the AST-level destructure walker. |
| Q7-A  | `lub({:bool}, {:int})` | Produces `:union` (NOT `{:int}`) — preserves bool-coercion path through `py_add` / `py_mult`. |
| Q8-A  | Closure-captured types | `Name` lookup walks `type_stack` inner→outer; first hit wins. |
| Q9    | F-string segments | PR 4 extends to `Nodes.FString` — specialize unformatted `{:str}` / `{:int}` segments. |
| Q10   | Walrus `(x := expr)` | Bind-as-expression; folded into PR 1 alongside Assign. |
| Q11   | Inference perf | No memoisation initially; revisit if PR 2 benchmarks show inference is hot. |
| —     | `Compare.pair_ast` API change | Only internal callers (`compare.ex:25, 87`); safe to grow arity. |

## Approach

A new `Pylixir.TypeInfer` module owns a small lattice + inference
walker. State threads through `Pylixir.Context` as a new `:types`
field. Every helper-emit site grows a single specialization branch
that fires when both operand types are known; the existing
polymorphic emit is preserved as the fallback clause.

Once specialization removes all references to (say) `py_add`,
`HelpersCodegen.helpers_ast_for/1` (the tree-shaking pass already
shipped) drops `py_add` from the splice automatically — no manual
helper-pruning needed.

### Type lattice (`lib/pylixir/type_infer.ex`)

```elixir
@type t ::
        :any                                       # top / unknown
        | {:int} | {:int_lit_nonneg}               # int_lit_nonneg <: int
        | {:float} | {:bool}
        | {:str} | {:none}
        | {:list, t()}                             # elem type — refined only on init from literal, demoted to :any on any mutation
        | {:tuple, [t()]} | {:tuple, :any_arity}
        | {:dict, t(), t()}                        # key, value — value type is informational ONLY (subscript reads still return :any)
        | {:set}                                   # MapSet
        | {:union, MapSet.t(t())}
        | :bottom
```

Join rule `lub/2`:
- `lub(t, t) = t`
- `lub(:any, _) = :any`
- `lub({:int}, {:float}) = {:float}` (numeric tower)
- `lub({:list, a}, {:list, b}) = {:list, lub(a, b)}` (and dict)
- **`lub({:bool}, {:int}) = {:union, MapSet.new([{:bool}, {:int}])}`**
  (decision Q7-A) — bool is NOT folded into the numeric tower.
  `True + 1 = 2` in Python; `true + 1` raises ArithmeticError in
  Elixir. Keeping bool as a distinct lattice point that produces a
  union when joined with anything numeric prevents the join-then-
  specialize path from emitting an unguarded `+` over a value that
  may be a bare boolean at runtime. Same treatment for
  `lub({:bool}, {:float})`. `py_add`'s `is_boolean(a)` /
  `is_boolean(b)` clauses handle the coercion correctly.
- otherwise → `{:union, MapSet.new([a, b])}` — union is a *fact
  carrier*, never specializes. This guarantees additive-only.

#### `{:int_lit_nonneg}` refinement rules

`{:int_lit_nonneg}` is a *refinement subtype* of `{:int}` introduced
solely to gate `String.duplicate` / `List.duplicate` specialization
(decision Q2-B). It must not leak elsewhere or grow its own algebra.
Three pinned rules:

1. **Subtype**: `{:int_lit_nonneg}` satisfies `is_int?/1`. Every BinOp /
   Compare / Subscript rule that matches `{:int}` also matches
   `{:int_lit_nonneg}`. No site other than `bin_op_ast` for `Mult`
   inspects the refinement explicitly.
2. **Join**:
   - `lub({:int_lit_nonneg}, {:int_lit_nonneg}) = {:int_lit_nonneg}`
   - `lub({:int_lit_nonneg}, {:int}) = {:int}` (refinement lost)
   - `lub({:int_lit_nonneg}, t)` for any other `t` = `lub({:int}, t)`
     (promote to `{:int}` first, then apply the normal rules — e.g.
     vs `{:float}` gives `{:float}`, vs `{:bool}` gives the bool-union)
3. **Introduction**: produced **only** by `infer_expr/2` on a
   `Constant(value=n)` node where `is_integer(n) and n >= 0`. No other
   inference rule produces it. In particular, `BinOp` of two
   `{:int_lit_nonneg}` operands yields `{:int}`, not
   `{:int_lit_nonneg}` — `Sub` can go negative, and accepting the
   missed specialization on `(3 + 5) * "x"` is cheaper than getting
   `Sub` wrong.

Predicates `is_int?/1`, `is_str?/1`, `is_list?/1`, `is_dict?/1`,
`is_set?/1` fire only on the concrete tags (with `is_int?/1` matching
both `{:int}` and `{:int_lit_nonneg}` per rule 1). Unions and `:any`
always fall through to the polymorphic helper.

#### Dict-value subscripts return `:any` (decision Q1-B)

`py_getitem(map, k)` returns `nil` for missing keys *by design* — that's
what makes `d[k] += 1` work on a regular `%{}` (defaultdict idiom;
`runtime_helpers.ex:417-425`). `py_add(nil, b) = b` is the matching
half. If subscript reads were refined to the dict's value type, code
like `counts = {}; counts[k] + 1` would specialize `+` and crash on
the first nil at runtime.

Rule: **`Subscript {:dict, _, _}` always returns `:any`**, regardless
of the recorded value type. The dict-value slot in the lattice is
informational only. Site-level specialization (emitting `Map.get(v, k)`
directly because we know the *collection* is a dict) still fires; only
the post-read type stays `:any`.

#### Mutation demotes container element types (decision Q5-C)

A `{:list, e}` or `{:dict, k, v}` is **frozen on init from a literal**.
Any mutating site for the name demotes the type in `ctx.types` to
`{:list, :any}` / `{:dict, :any, :any}` — container tag preserved (so
`len` / `in` / Subscript-site specialization still fire), but element
refinement is lost. Mutating sites:

- `xs[i] = v` (Subscript-Assign, `Nodes.Assign.single_target_assign/4`
  Subscript-target clause)
- `xs[a:b] = v` (slice-Assign — same clause, Slice branch)
- `xs.append(v)` / `.extend` / `.insert` / `.sort` / `.reverse` /
  `.clear` / `.pop` (`Nodes.Mutations.emit/6`)
- `d[k] = v` (same Subscript-Assign clause)
- `d.update(...)` / `d.pop(...)` / `d.setdefault(...)` / `d.clear()`
- `del xs[i]` / `del d[k]` (Delete clause)

Implementation: a `TypeInfer.demote/2` call from each mutation site
reducing the name's element type to `:any`. Mirrors
`ModuleAnalysis.mutation_free_literal_names`'s "untouched after init"
notion at the type-system level.

### Where inference lives

New module `Pylixir.TypeInfer` at `lib/pylixir/type_infer.ex`.
`Pylixir.Context` gains four fields:

```elixir
:types :: %{optional(String.t()) => TypeInfer.t()}        # current scope
:type_stack :: [%{optional(String.t()) => TypeInfer.t()}] # parent scopes
:fn_signatures :: %{String.t() => {[TypeInfer.t()], TypeInfer.t()}}
:heap_types :: %{optional(String.t()) => TypeInfer.t()}   # process-dict-backed names
```

`type_stack` push/pops on the same scope boundaries the existing
`:scopes` push/pops (Lambda, comprehensions, FunctionDef, ClassDef).
Per-conversion state — discarded when conversion finishes.

Each `type_stack` frame is `{kind, type_map}` where `kind` is one of
`:module | :function | :class | :lambda | :comprehension`. The kind
tag is needed by `walrus_target_scope/1` (PEP 572 — walrus escapes
comprehensions and lambdas but stops at function/class/module
boundaries). `ctx.types` is conceptually the head of the stack;
`type_stack` holds the parent frames.

Why threaded into Context vs a separate pre-pass:
- Conversion already threads context — adding a field is a one-line
  change at each clause that needs it.
- Sequential per-statement inference matches Python's flow-sensitive
  narrowing (`x = 1; x = "a"; len(x)` — `len(x)` sees `{:str}`).
- The Python AST has no stable node-ID, so a side-table-by-node would
  need its own indexing scheme.

Why NOT a post-conversion rewrite pass over the produced Elixir AST:
the temptation is to keep the converter untouched and add a pattern-
match pass that rewrites `{:py_add, _, [l, r]}` → `{:+, _, [l, r]}`
when both operands are statically `{:int}`. Decoupled, easy to disable.
The problem: **conversion is a lossy lowering**. By the time we have
Elixir AST, Python-level facts that the inference relies on are gone:

- **Flow-sensitive name binding.** Python `x = 1; … x = "a"; len(x)`
  is linear and trivially walkable on the Python AST. After conversion
  it's `{:=, _, [{:x, _, _}, 1]}` … `{:=, _, [{:x, _, _}, "a"]}` …
  `py_len(x)` — recovering "which write reaches this read" requires
  re-doing scope analysis on a representation that no longer matches
  Python's scope rules (Elixir is lexical-block-scoped, Python is
  function-scoped).
- **Structural shape erasure.** `for`-loops become `Enum.reduce`,
  comprehensions become `for`-comprehensions, classes become module-
  with-struct, `lambda` becomes `fn`, walrus is inlined, augmented
  assigns get desugared. The Python AST nodes that drive scope/branch
  type-merging rules (For, If, Try, IfExp, AugAssign) no longer exist
  as distinguishable shapes in the output.
- **Constant subtype info.** Python's `Constant(value=True)` carries
  *bool* identity in the AST — needed by decision Q7-A (don't lub bool
  into int) and the `True + 1 → ArithmeticError` hazard. After conversion
  `True` is a plain Elixir `true`; the bool-vs-int-subclass distinction
  is lost.
- **Slice-shape inspection** (Site 4). Subscript specialization picks
  between `Map.get` / `Enum.at` / `py_getitem` based on the *slice node's
  shape* — "is the slice a literal nonneg int?" Trivial on Python AST's
  `Subscript.slice`; on lowered Elixir the slice is already a converted
  expression and the literal-vs-computed distinction requires
  re-classifying the AST.
- **Mutation tracking** (decision Q5-C). The demotion sites are Python
  AST nodes — Subscript-Assign, slice-Assign, `.append`/`.extend`/…
  method calls, `del`. After lowering, `.append` is `py_list_append(xs, v)`
  in some sites and inline `[v | xs]` in others; uniformly recognizing
  "this is a mutation of name `xs`" is no longer one AST shape but
  several emit patterns.
- **Module-attribute seeding** (A7). `LiteralFold.fold/1` runs on the
  Python AST and produces a BEAM term; the produced Elixir is a
  literal expression with no `@var_name` annotation surviving. Post-
  pass would have to re-derive which names are module attrs.

In short: the Python AST is the *source of truth* for the type facts
this pass needs. A post-conversion pass would spend most of its budget
reconstructing Python semantics from a representation that has been
deliberately re-shaped for Elixir. In-conversion threading reads each
fact at the point where it's structurally obvious.

A pre-pass `TypeInfer.module_summary/1` runs from the Module clause to
fill `fn_signatures`. It iterates to a bounded fixed point (≤5 rounds):
each round walks every top-level FunctionDef, re-inferring caller arg
types and return types using the *previous* round's `fn_signatures`.
Stops when no entry changes or the iteration cap is hit (any unstable
entry falls back to `:any`).

#### Inter-procedural fixed-point (decision Q3-C)

Without typed function parameters, almost nothing inside a function
body specializes — `def fib(n): return fib(n-1) + fib(n-2)` keeps every
arithmetic op polymorphic because `n` is `:any`. `module_summary/1`
runs a **bounded fixed-point** over both param types and return types:

```
fn_signatures = %{}                # round 0: all params/returns :any
for round <- 1..MAX_ROUNDS do
  next = %{}
  for each top-level def f(p1, p2, …) in module:
    # 1. Re-infer caller arg types using last round's signatures.
    #    Call sites lexically INSIDE f's own body are skipped — they
    #    can't pin params they only re-assert. See "Recursive call
    #    sites contribute :bottom" below.
    call_sites = find_calls(module, name: f) -- calls_inside(f.body)
    param_types = lub_across(call_sites, fn(args) ->
      Enum.map(args, &infer_expr(&1, ctx_with(fn_signatures)))
    end)
    # 2. Re-infer return type using primed param types.
    body_ctx = ctx_with(types: zip(params, param_types), fn_signatures)
    return_type = lub_of_returns(f.body, body_ctx)
    next[f] = {param_types, return_type}
  end
  if next == fn_signatures, break  # converged
  fn_signatures = next
end
# anything still :any after MAX_ROUNDS remains :any (conservative)
```

`MAX_ROUNDS = 5` covers realistic call-chain depths; convergence is
typical in 2–3 rounds for non-recursive code. Recursive cycles either
converge (e.g. `fib(int) → int` stable on round 2) or hit the cap and
fall back — never wrong, just imprecise.

Recursive call sites contribute `:bottom` (i.e. are excluded from the
param-type lub). Reason: at module-summary level the in-body call
`fib(n-1)` is inferred against an empty function-local context, so `n`
resolves to nothing and the arg would lub as `:any` — poisoning the
external callers' useful signals. Skipping in-body calls means
external callers pin the type, and the body's own recursive calls just
re-assert that type via the primed `param_types` in step 2. For
`def fib(n): return fib(n-1) + fib(n-2)` with one external `fib(10)`:
round 1's external lub gives `n: {:int_lit_nonneg}`, round 2's body
inference promotes via `Sub` to `{:int}`, and the return type
converges. Without this exclusion, `fib` never specializes regardless
of how many rounds run.

Mutual recursion follows the same rule transitively — only call sites
*outside* the strongly-connected component pin the types, and within-
SCC calls re-assert via the next round's body inference.

Caveats:
- Different concrete types at different external call sites → union →
  `:any` for that param.
- Variadic / keyword-only / default-valued params: treat as `:any`.
- A function with *only* recursive callers (e.g. defined-but-never-
  externally-called) gets `:any` params forever. Correct: there's no
  signal to derive types from.

The per-round body re-walk uses the **same two-pass loop inference**
as the conversion pass (edge case #3). A `Call(Name=g)` nested inside
a `For`/`While` body inside `f` therefore contributes to `g`'s
param-type lub with the same precision the conversion pass would see,
preserving inter-procedural signal through loops.

Cost: per round, one walk of the module body + one type-inference per
call site (with each loop body inferred twice). `O(rounds × #defs ×
(#calls + #loops))`. Still linear in code size, negligible vs the
conversion pass itself.

### Flow rules (`TypeInfer.infer_expr/2`)

| Construct                              | Rule |
|---|---|
| `Constant` (int/float/str/bool/None)   | dispatch on the BEAM term of `node["value"]` — `is_boolean/1` → `{:bool}` (checked FIRST so `True`/`False` don't fall through to `is_integer/1`); `is_integer/1 and >= 0` → `{:int_lit_nonneg}`; `is_integer/1` → `{:int}`; `is_float/1` → `{:float}`; `is_binary/1` → `{:str}`; `is_nil/1` → `{:none}`; otherwise `:any`. Matches the ordering in `Converter.convert/2`'s Constant clause (`converter.ex:868-872`). |
| `List` / `Tuple` / `Set` / `Dict` lit  | container with elem types joined via `lub` |
| `Name`                                 | `lookup(id, [ctx.types | ctx.type_stack])` — walks scope stack inner→outer, first hit wins (decision Q8-A; lexical capture for closures) |
| `NamedExpr (x := expr)`                | walrus: target scope follows PEP 572 — bind to the innermost **enclosing function/class/module** scope, *skipping* any comprehension or lambda frames in between. Helper `walrus_target_scope(ctx) :: pos_integer` walks `[ctx.types \| ctx.type_stack]` from innermost outward and returns the first frame index that is not tagged `:comprehension` / `:lambda` (scope frames carry a kind tag, set when pushed in PR 1). Bind there; the value of the expression has that type in the *current* scope as well (so `[y for y in xs if (n := len(y)) > 0]` types `n` both for the predicate's reuse and for post-comprehension reads). After the comprehension/lambda exits, the parent-scope binding persists (decision Q10) |
| `BinOp Add (int, int)`                 | `{:int}` |
| `BinOp Add (str, str)`                 | `{:str}` |
| `BinOp Add (list, list)`               | `{:list, lub}` |
| `BinOp Mult (str, int) / (int, str)`   | `{:str}` |
| `BinOp Mult (list, int) / (int, list)` | `{:list, elem}` |
| `Compare`                              | `{:bool}` |
| `BoolOp And/Or`                        | `lub(left, right)` |
| `Call(Name=builtin)`                   | hardcoded return table (see PR 9) |
| `Call(Name=user_fn)`                   | `ctx.fn_signatures[name]` or `:any` |
| `Subscript {:list, e}, _`              | `e` |
| `Subscript {:dict, _, _}, _`           | `:any` — see "Dict-value subscripts" above |
| `Subscript {:tuple, ts}, literal int`  | `Enum.at(ts, i)` |
| `Subscript {:str}, _`                  | `{:str}` |
| `IfExp`                                | `lub(then_arm, else_arm)` |
| `Assign target = expr`                 | `bind_pattern(target, infer_expr(expr), ctx)` — see "Pattern binding" below; covers bare Name, tuple/list destructure, starred unpack, multi-target chains, and Subscript-target mutation demotion (decision Q6-A) |
| `AugAssign x op= expr`                 | `bind(x, infer(BinOp(x, op, expr)))` for Name targets; for Subscript / Attribute targets, demote the container per Q5-C and skip type binding |
| `For target in iter` / `While`         | bind target to `elem_of(iter_type)` (For only). Body inferred via the two-pass scheme (edge case #3). If an `else` clause is present, it starts with the post-body lub'd types; post-loop state = `lub_branches(body_end_types, else_end_types)` reusing the same helper as `If`/`Try` (Q8). Without `else`: post-loop state = the two-pass lub'd types. `break` / `continue` don't perturb the type map — neither rebinds names |
| `If statement`                         | per-branch type maps merged via `lub` |
| `Try statement`                        | per-branch lub mirroring `If`. Infer each clause independently: try-body, each `except` handler (starting types = post-try-body), `else` (starting types = post-try-body; runs only on successful try). Post-try state = `lub(try_body_end, except_1_end, …, except_n_end, else_end?)`. **`finally` escape**: every name written in the try-body is pessimized to `:any` for the duration of the `finally` body — accounts for the "raise before assignment completed" path where the binding may never have happened; restore the post-try state after `finally` ends. Soundness: covers the rare unsound case (name bound only inside try-body, raised pre-assignment, then read in `finally`) without sacrificing precision elsewhere |
| `FunctionDef` params                   | Seeded from `call_site_param_scan/1` lub of all callers' arg types; `:any` if no callers or mixed types |
| `Return`                               | record into `fn_signatures` via `lub` |

`elem_of/1`:
- `{:list, e}` → `e`
- `{:str}` → `{:str}`
- `{:tuple, ts}` → `lub` over `ts`
- `{:dict, k, _}` → `k` (Python iterates dict keys)
- `{:set}` → `:any`
- else → `:any`

#### Pattern binding (decision Q6-A)

`bind_pattern(target_node, source_type, ctx)` is the structural mirror
of `Nodes.Assign`'s existing target destructure. Recursive, bounded
depth (typical real code is ≤2 levels). Reuses the *shape walk* from
the existing destructure machinery; just substitutes "lattice type"
for "AST" at the leaves.

| Target shape                        | Action |
|---|---|
| `Name(id)`                          | `ctx.types = Map.put(ctx.types, id, source_type)` |
| `Tuple(elts)` / `List(elts)`        | **first**: if any elt is `Starred`, dispatch to the Starred row's position-aware logic (which consumes the parent's `elts` and `source_type` together). Otherwise: if `source_type = {:tuple, ts}` with **matching** arity, zip elts and ts and recurse per-element. If `{:tuple, ts}` with **mismatched** arity: recurse each elt with `:any` (the destructure will raise `ValueError` at runtime — same as today; inference shouldn't warn). If `{:tuple, :any_arity}`: recurse each elt with `:any`. If `source_type = {:list, e}`: recurse each elt with `e`. Else: recurse each elt with `:any`. |
| `Starred(value=Name(id))` (inside Tuple/List target) | position-aware unpack: let `n_fixed = len(siblings) - 1`, `i = star_index`. If `source_type = {:tuple, ts}` with `len(ts) >= n_fixed`: front fixed targets bind to `ts[0..i-1]`, rear fixed targets bind to `ts[-(n_fixed-i)..-1]`, Starred binds to `{:list, lub(ts[i..-(n_fixed-i)-1])}` (slice of middle types lub'd; if the slice is empty, `{:list, :bottom}` → `{:list, :any}`). If `source_type = {:list, e}`: every fixed sibling binds to `e`, Starred binds to `{:list, e}`. If `{:tuple, :any_arity}` or anything else: every fixed sibling binds to `:any`, Starred binds to `{:list, :any}`. Driven from the parent Tuple/List `bind_pattern` clause — Starred row is consulted with full sibling context, not in isolation |
| `Subscript(value, slice)`           | demote `value`'s name's container elem-type to `:any` per Q5-C; no name binding |
| `Attribute(value, attr)`            | no type binding (instance attrs read as `:any`) |
| multi-target chain `a = b = c = …`  | `Assign` already lowers to one Python `Assign(targets=[a, b, c], …)`; iterate targets, calling `bind_pattern(target, source_type, ctx)` for each |

Examples:
- `a, b = (1, "hi")` → source `{:tuple, [{:int}, {:str}]}` → `a := {:int}`, `b := {:str}`.
- `for i, x in enumerate(xs)` → For target `Tuple([i, x])`, iter type
  `{:list, {:tuple, [{:int}, e]}}`. `elem_of` gives `{:tuple, [{:int}, e]}`.
  `bind_pattern` recurses: `i := {:int}`, `x := e`.
- `a, *rest = [1, 2, 3]` → source `{:list, {:int}}`. `a := {:int}`,
  `rest := {:list, {:int}}`.
- `m[k] = v` → Subscript target. Demote `m`'s elem-type to `:any`. No
  name binding.

### Specialization sites

Each gains a single branch in front of the existing polymorphic emit.

#### Site 1 — `bin_op_ast` at `lib/pylixir/converter.ex:1219`

`bin_op_ast/4` becomes `bin_op_ast/6` taking `lt, rt`. The two callers
(BinOp clause around `converter.ex:119`, AugAssign helper around line
1252) compute types from the *Python* AST args before recursive
`convert/2` — types of the user-level expressions, not of the emitted
Elixir AST.

```elixir
defp bin_op_ast(%{"_type" => "Add"}, l, r, _node, {:int}, {:int}),   do: {:+, [], [l, r]}
defp bin_op_ast(%{"_type" => "Add"}, l, r, _node, {:str}, {:str}),   do: {:<>, [], [l, r]}
defp bin_op_ast(%{"_type" => "Add"}, l, r, _node, {:list,_},{:list,_}), do: {:++, [], [l, r]}
defp bin_op_ast(%{"_type" => "Sub"}, l, r, _node, {:int}, {:int}),   do: {:-, [], [l, r]}
defp bin_op_ast(%{"_type" => "Mult"}, l, r, _node, {:int}, {:int}),  do: {:*, [], [l, r]}
# … and the existing catch-all
defp bin_op_ast(op, l, r, node, _lt, _rt), do: {existing polymorphic fallback}
```

**Mult on `str|list × int` requires a literal-non-negative guard (decision Q2-B).**
`py_mult(s, n)` returns `""` when `n <= 0`, but `String.duplicate(s, -1)`
raises FunctionClauseError; `List.duplicate(l, -1)` raises
ArgumentError. Python semantics: `"abc" * -1 == ""`. So
`String.duplicate` is only safe to emit when the int operand is a
literal non-negative `Constant`:

```elixir
defp bin_op_ast(%{"_type" => "Mult"}, l, r, _node, {:str}, {:int_lit_nonneg}),
  do: {{:., [], [{:__aliases__, [], [:String]}, :duplicate]}, [], [l, r]}

defp bin_op_ast(%{"_type" => "Mult"}, l, r, _node, {:int_lit_nonneg}, {:str}),
  do: {{:., [], [{:__aliases__, [], [:String]}, :duplicate]}, [], [r, l]}
```

`{:int_lit_nonneg}` is a refinement-only tag (introduced by
`TypeInfer.infer_expr/2` when seeing `Constant(value=n)` with
`is_integer(n) and n >= 0`). It satisfies `is_int?/1` for all
other rules. Same shape for `{:list, _} * {:int_lit_nonneg}` →
`List.duplicate/2 |> Enum.concat/1`.

Dynamic-int multiplication (`[0] * n` where `n` came from input) stays
polymorphic — falls through to `py_mult`. Eval-corpus literal-banner
patterns (`"-" * 80`, `[0] * 100`) still specialize.

#### Site 2 — `Pylixir.Builtins.emit` at `lib/pylixir/builtins.ex:137`

Extend signature `emit/3` → `emit/4` with `arg_types :: [t()]`. Single
caller (the Call routing in `converter.ex` near line 380) computes
types via `TypeInfer.infer_expr/2` on the original Python args.

```elixir
def emit("len", [x], _kw, [{:list, _}]),  do: {:ok, {:length, [], [x]}}
def emit("len", [x], _kw, [{:str}]),      do: {:ok, {{:., [], [{:__aliases__, [], [:String]}, :length]}, [], [x]}}
def emit("len", [x], _kw, [{:dict,_,_}]), do: {:ok, {:map_size, [], [x]}}
def emit("len", [x], _kw, [{:set}]),      do: {:ok, {{:., [], [{:__aliases__, [], [:MapSet]}, :size]}, [], [x]}}
def emit("len", [x], _kw, [{:tuple, _}]), do: {:ok, {:tuple_size, [], [x]}}
def emit("len", [x], _kw, _),             do: {:ok, {:py_len, [], [x]}}  # fallback
```

Same shape for `int`, `str`, `bool`, `sum`, and the iter consumers
(see Site 5).

#### Site 3 — `Pylixir.Nodes.Compare.pair_ast` at `lib/pylixir/nodes/compare.ex`

Extend `pair_ast/3` → `pair_ast/5` with `lt, rt`. Specializations:

```elixir
def pair_ast(%{"_type" => "In"}, l, r, _, {:list, _}),    do: {:in, [], [l, r]}
def pair_ast(%{"_type" => "In"}, l, r, _, {:set}),        do: {{:., [], [{:__aliases__, [], [:MapSet]}, :member?]}, [], [r, l]}
def pair_ast(%{"_type" => "In"}, l, r, _, {:dict, _, _}), do: {{:., [], [{:__aliases__, [], [:Map]}, :has_key?]}, [], [r, l]}
def pair_ast(%{"_type" => "In"}, l, r, {:str},{:str}),    do: {{:., [], [{:__aliases__, [], [:String]}, :contains?]}, [], [r, l]}
def pair_ast(%{"_type" => "In"}, l, r, _, _),             do: {:py_in, [], [l, r]}
```

`NotIn` wraps each in `{:!, [], [...]}`.

#### Site 4 — `Subscript` clause in `lib/pylixir/converter.ex`

Inside the Subscript convert clause: if `value_type` is `{:dict, _, _}`
emit `Map.get(v, k)`. If `{:list, _}` and the slice is a `Constant`
integer literal `>= 0`, emit `Enum.at(v, k)`. (Negative indices /
non-literal indices keep using `py_getitem` because the wrap-around
logic lives there.) Else fallback.

#### Site 5 — `py_iter_to_list` elision

Every site that wraps an arg with `{:py_iter_to_list, [], [x]}` —
`builtins.ex` lines ~167/183/192/198, `nodes/loop.ex:752`,
`nodes/assign.ex:809/817/844` — gains a `case TypeInfer.infer_expr/2`:
when the arg type is `{:list, _}`, emit the arg AST directly. Big
win — most user lists never need the coercion.

#### Site 6 — F-string `FormattedValue` segments (decision Q9)

`Pylixir.Nodes.FString` lowers `f"{x}"` to a series of `<>` concats
with `py_str(x)` / `py_format_value(x, spec)` calls per segment.
Specialize the unformatted (`spec == nil`) case based on segment type:

```elixir
defp emit_segment(value_node, nil = _spec, ctx) do
  case TypeInfer.infer_expr(value_node, ctx) do
    {:str}                  -> convert(value_node, ctx)              # py_str is identity on binary; drop the call
    {:int}                  -> {:., [], [{:__aliases__, [], [:Integer]}, :to_string]}, [], [<converted>]}
    _                       -> {:py_str, [], [<converted>]}           # existing fallback
  end
end
```

The format-spec case (`f"{x:.2f}"`) keeps `py_format_value` — the
spec parsing isn't worth inlining. Most eval-corpus f-strings have no
spec (`f"{n} items"`), so the unformatted case is the high-volume
target.

### Edge cases & hazards

1. **Branch with diverging types** — `IfExp` joins via `lub`, producing
   `{:union, …}` which never specializes. Conservative ✓.
2. **Reassignment to a different type** — flow-sensitive: each `Assign`
   *replaces* the recorded type. Matches Python.
3. **Loop-mutated names** — **two-pass** inference for `For` and
   `While` bodies. Pass 1: walk the body with `TypeInfer` only (no
   AST emission) starting from the pre-loop `ctx.types`; each Assign /
   AugAssign inside the body updates a working type map. At the end,
   for every name written in the body, set the type to
   `lub(pre_loop_type, body_end_type)`. Pass 2: convert the body with
   the lub'd types in scope. Cost is one extra inference walk per
   loop — linear, no AST output. Use `Pylixir.AST.Walk.walk_scope/3`
   for the pass-1 traversal. Preserves the accumulator-int idiom
   (`total = 0; for x in xs: total = total + x` keeps `total: {:int}`
   throughout, so `total + x` specializes); falls back to `:union` /
   `:any` only when the body genuinely assigns a heterogeneous type.
4. **Recursion** — `fn_signatures` converges via the bounded fixed-point
   loop in `module_summary/1`. First round: self-calls see `:any`. Each
   subsequent round refines using the prior round's signatures.
   `fib(int) → int` typically stabilizes by round 2.
5. **`input()`** — return type `{:str}` via the stdlib return table.
6. **Mutating methods (`list.append`, `dict.update`)** — name's
   container type stays, but elem type widens to `:any` after the
   call. Hook into `Nodes.Mutations.emit/6`.
7. **`global` / `nonlocal` / `mutable_module_dicts`** — Process-dict-
   backed names. PR 3 types these by their *initial* top-level assign
   (literal-init rule), then demotes element slots to `:any` per Q5-C
   (these names are mutable by definition). Stored in
   `ctx.heap_types[name]`. Reads through `process_dict_get(name)`
   consult that. **Container tag only** — element-type precision is
   not modeled. Subscript-Assigns / `Nodes.Mutations` on these names
   are no-ops from the type-system perspective because element types
   are already `:any`. If the initial assign isn't a literal (e.g.
   `m = make_dict()` with no return-type info), the name stays `:any`
   in `heap_types`.
8. **Module attributes (`@var_name`)** — `LiteralFold.fold/1` already
   computes the BEAM term at compile time. Add `TypeInfer.type_of_term/1`
   and seed `ctx.types` at module entry. Every const-folded constant
   becomes a typed source.
9. **`bool` + `int` arithmetic** — `lub({:bool},{:int}) = {:int}` but
   skip specialization when *either* side is `{:bool}` — `py_add`'s
   bool-to-int coercion is hard to replicate inline without bloating
   the emitted expr.
10. **`isinstance(x, T)` branch narrowing** — `If` clause inspects its
    `test` for the `isinstance(Name(id), Constant_or_NameOfType)` shape.
    Inside the `body`, `ctx.types[id]` is overridden to the lattice
    type matching `T` (`int`/`str`/`list`/`dict`/`set`/`tuple`/`bool`/
    `float`); the `orelse` branch sees the *complement* via `lub_complement/2`
    (best-effort — if the original type is `:any`, complement stays
    `:any`). After the If, the per-branch maps merge via `lub` as usual.
    Tuple-of-types (`isinstance(x, (int, str))`) handled by unioning the
    matched types. Other test shapes (e.g. `type(x) is int`, `x is None`)
    fall through unchanged.
11. **AugAssign on Subscript target (`x[k] += v`)** — type of `x[k]`
    may change in unpredictable ways; the subscript-assign clause stays
    unmodified. Element-type demotion still fires via Q5-C: `x`'s
    container elem-type goes to `:any`.

12. **Subscript-Assign / slice-Assign on typed lists or dicts** —
    decision Q5-C: `xs[i] = v` demotes `ctx.types[xs]` to `{:list, :any}`;
    `xs[a:b] = v` does the same. Dicts likewise. Prevents wrong
    specialization in downstream reads after mutation.

13. **`py_mult(str|list, int)` with non-literal int operand** — decision
    Q2-B: only the literal-non-negative case specializes. Anything
    computed at runtime falls through to `py_mult`, which has the
    `b > 0` / `b <= 0` clauses already.

14. **Dict-value subscript reads** — decision Q1-B: always `:any`,
    regardless of `{:dict, k, v}`'s recorded `v`. Preserves the
    `py_add(nil, n) = n` defaultdict idiom from `runtime_helpers.ex:417`.

15. **`bool` × `int` arithmetic** — decision Q7-A: `lub({:bool}, {:int})`
    is a `:union`, not `{:int}`. Specialization never fires when *either*
    operand is bool-tainted (including via a prior lub that involved a
    bool branch). Avoids the `true + 1 → ArithmeticError` runtime crash.

16. **Closure-captured types** — decision Q8-A: `Name` lookup walks
    `[ctx.types | ctx.type_stack]` inner→outer. A `lambda y: outer_x + y`
    inside a function that bound `outer_x = 5` sees `outer_x : {:int}`
    via the stack walk, so `outer_x + y` can specialize if `y` is also
    typed. Without this, every closure-captured name would be `:any`
    and lambdas would never benefit.

17. **Inference perf — re-walking the Python AST** — inference walks
    each AST subtree twice (once for `infer_expr/2`, once for `convert/2`).
    That's linear, not quadratic. *However*, inside the
    `bin_op_ast` / `pair_ast` / specialization sites we call
    `infer_expr/2` on operand nodes that the surrounding `convert/2`
    will *also* recurse into. For very deep BinOp chains this can
    compound. **No memoisation by default.** If benchmarks show
    inference is hot, add a per-conversion `MapSet`-backed memo keyed
    by node identity — Python AST dicts are sharable enough that a
    `Map.fetch/2` keyed on `{lineno, col_offset, _type}` will hit most
    of the time. Punt until measured.

### Phasing (13 PR-sized slices)

Each PR is independently shippable — the inference fallback is `:any`,
which always emits the polymorphic helper. Rolling back any single PR
restores prior behaviour.

Ordering principle: **soundness before yield, plumbing before consumers.**
PR 1 lands the lattice *and* every mutation-demotion hook together, so
that no later PR can read a stale element type. PR 3 lands heap typing
for `mutable_module_dicts` *before* the specialization sites that
consume those types (PRs 4–6), so module-dict patterns benefit from
specs as they ship. PRs 10–13 expand inference reach (inter-procedural,
branch-sensitive).

| PR  | Scope |
|---|---|
| 1   | `TypeInfer` module skeleton + `:types`/`:type_stack`/`:fn_signatures`/`:heap_types` fields on Context. `infer_expr/2` for literals + scope-stack Name lookup. `bind_pattern/3` covering Name/Tuple/List/Starred targets. Walrus `NamedExpr`, AugAssign on Name. **Mutation demotion via `TypeInfer.demote/2` hooked into every Subscript-Assign, slice-Assign, `Nodes.Mutations` site, and Delete clause** (decision Q5-C). No specialization yet — verify plumbing with unit tests asserting types are recorded and demoted correctly. |
| 2   | `bin_op_ast` specialization for Add/Sub/Mult/Div/Mod (int / str / list / tuple). Mult on str/list × int gated on `{:int_lit_nonneg}` (decision Q2-B). |
| 3   | **Heap typing for `mutable_module_dicts`** — **container tag only**, element types stay `:any` per Q5-C (these names are by definition mutated, so element refinement is unsound). For each name in `context.mutable_module_dicts`, `module_summary/1` finds its initial top-level assign, types the RHS via the literal-init rule, then demotes element slots to `:any` (e.g. `m = {1: "a"}` → `{:dict, :any, :any}`, `xs = [1, 2]` → `{:list, :any}`). Stored in `ctx.heap_types[name]`. Reads through `process_dict_get(name)` consult `ctx.heap_types`. No need to scan or lub Subscript-Assign sites — Q5-C demotion is implicit because element types start `:any`. Lands BEFORE PR 4–6 so that `len(m)` / `k in m` / `m[k]` specialize for module-level dicts and lists as soon as those PRs ship. |
| 4   | `Builtins.emit/3` → `emit/4`; specialize `len`, `int`, `str`, `bool`. Extend `Pylixir.Nodes.FString` to specialize per-segment `py_str` for `{:str}` and `{:int}` (decision Q9). |
| 5   | `Compare.pair_ast` specialization for `In` / `NotIn`. |
| 6   | Subscript clause specialization (`{:dict, _, _}` → `Map.get`; `{:list, _}` + literal nonneg int → `Enum.at`). Read-type of dict subscripts stays `:any` (decision Q1-B). |
| 7   | `py_iter_to_list` elision across the 8 emission sites. |
| 8   | Module-attribute seeding via `LiteralFold.fold/1` + `type_of_term/1`. |
| 9   | Stdlib return-type table for builtins (`range`, `sorted`, `enumerate`, `zip`, `map`, `filter`, `sum`, `min`, `max`, `input`). |
| 10  | **Inter-procedural fixed-point** (decision Q3-C) — `module_summary/1` iterates param + return types until `fn_signatures` is stable, capped at 5 rounds. External callers pin params (recursive call sites excluded — see "Recursive call sites contribute `:bottom`"); per-round body re-walk reuses the two-pass loop inference from edge case #3. |
| 11  | For-loop / comprehension target typing (`elem_of(iter_type)`). Loop-body mutated-name pre-walk via `AST.Walk.walk_scope/3`. |
| 12  | `If` / `IfExp` / `Try` branch-merge via `lub` — `lub` each branch's type map back into the parent. |
| 13  | **`isinstance(x, T)` branch narrowing** — `If` clause detects the test shape, narrows the True branch's `ctx.types[id]` to `T`'s lattice type, and narrows the False branch via best-effort complement. Tuple-of-types handled. Other test shapes pass through. |

### Deferred enhancements

Not part of this plan; flagged here so they're not re-discovered as
"missing." Each pays off only once preceding work lands and the
relevant lattice / signal is more refined than today.

- **`x is None` / `x == None` narrowing** in `If` test position. Same
  shape as `isinstance` narrowing (PR 13) — refines `x` to `{:none}` in
  the True branch and the complement in the False branch. **Why
  deferred**: pays off only when the pre-narrowing type of `x` is a
  union containing `{:none}` (then the False branch refines to the
  other arm). Phase-A lattice produces `{:none}`-bearing unions almost
  never — param types come from external call sites' lub, which the
  caller rarely passes `None` to. Revisit once user-supplied type
  hints or richer union propagation enters the lattice.
- **`type(x) is T` narrowing** — same family as `is None`; defer with
  it.
- **Attribute-access typing for class instances** — `self.attr` reads
  currently land as `:any`. A future pass could infer per-class
  attribute types from `__init__` Assigns. Out of scope for this plan;
  worth a separate design once heap-typing (PR 3) ships.
- **Inference memoisation** — see edge case #17. Re-walking AST
  subtrees is linear today; if PR 2 / PR 6 benchmarks flag inference
  as hot, add a per-conversion memo keyed on `{lineno, col_offset,
  _type}`.

## Files to modify

- `lib/pylixir/type_infer.ex` — **NEW**. Lattice, `infer_expr/2`,
  `bind/3`, `lub/2`, `elem_of/1`, `type_of_term/1`, `module_summary/1`.
- `lib/pylixir/context.ex` — add `:types`, `:type_stack`,
  `:fn_signatures`, `:heap_types` fields; update `Context.new/1`.
- `lib/pylixir/converter.ex` — BinOp clause (`~:119`), `bin_op_ast`
  (`~:1219`), Subscript clause (`~:558`), AugAssign helper (`~:1252`),
  Module clause to call `TypeInfer.module_summary/1`.
- `lib/pylixir/builtins.ex` — extend `emit/3` → `emit/4`; specialize
  `len`, `int`, `str`, `bool`, iter consumers.
- `lib/pylixir/nodes/compare.ex` — `pair_ast/3` → `pair_ast/5`.
- `lib/pylixir/nodes/assign.ex` — call `TypeInfer.bind/3` after every
  Assign / AugAssign that binds a Name target. Update the three
  `py_iter_to_list` sites (lines ~809/817/844).
- `lib/pylixir/nodes/loop.ex` — bind for-loop target type at line
  `~752`; pre-walk loop body for mutated names.
- `lib/pylixir/nodes/functions.ex` — push/pop type scope at lambda /
  function-def boundaries.
- `lib/pylixir/nodes/comprehension.ex` — push type scope; bind
  comp-target via `elem_of`.

Existing utilities to reuse:
- `Pylixir.LiteralFold.fold/1` — already converts module-attr literals
  to BEAM terms; `type_of_term/1` is a one-line wrapper.
- `Pylixir.AST.Walk.walk_scope/3` — scope-aware AST walker for the
  loop-mutated-names pre-walk.
- `Pylixir.HelpersCodegen.helpers_ast_for/1` — tree-shaking already
  drops helpers nobody references; no changes needed there.

## Test plan

Per PR:

1. **Inference unit tests** — `test/pylixir/type_infer_test.exs`,
   table-driven: hand-built Python AST → expected lattice type.
   Cover every flow rule.

2. **Negative-emission tests** — `test/pylixir/specialization_test.exs`:
   for each specialization site, assert the polymorphic helper does
   *not* appear when types are known.
   ```elixir
   test "1 + 2 emits Kernel.+ not py_add" do
     out = Pylixir.transpile("print(1 + 2)\n")
     refute out =~ "py_add"
     assert out =~ ~r/1\s*\+\s*2/
   end
   ```

3. **Helper-elision tests** — after specialization, the spliced helper
   block should not contain the eliminated helper:
   ```elixir
   test "py_add is tree-shaken when all uses are int+int" do
     refute Pylixir.transpile("x = 1 + 2\nprint(x)\n") =~ "def py_add"
   end
   ```

4. **Fallback tests** — polymorphic helper still fires when types
   are unknown (e.g. a user fn with no inferrable return).

5. **Property test** —
   `test/pylixir/specialization_property_test.exs`: with an env-var
   flag `PYLIXIR_NO_TYPE_INFER`, force `TypeInfer.infer_expr/2` to
   return `:any` always. For randomly generated programs that compile
   under both modes, assert *byte-identical stdout*. Proves
   specialization is a pure rewrite.

6. **Golden-fixture diff review** — for the first 3 PRs, manually
   review the diffs of every fixture's transpiled output. Diffs must
   be exclusively shrinks (helper-call → direct op, helper def gone).

7. **Output-size regression metric** — add a `mix eval.size` task
   that emits the average bytes per transpile across the 177-fixture
   corpus as CSV. CI gate: **no PR may increase** this number (flat is
   acceptable). PRs that ship specialization sites (2, 4, 5, 6, 7) are
   *expected* to decrease the number; if they don't, that's a signal
   the new spec isn't firing on the corpus and warrants investigation.
   PRs that ship inference plumbing without spec sites (1, 3, 8–13)
   may legitimately be flat — they unlock future PRs without immediate
   shrinkage.

## Verification

```bash
# Per-PR unit tests
mix test test/pylixir/type_infer_test.exs
mix test test/pylixir/specialization_test.exs

# Full safety net — must stay 100% green
mix test

# Eval-corpus pass rate — must stay at 100.0% / not drop
cd tools/eval && mix eval.run --skip 1000 --limit 1000 --name synthetic_sft

# Property test (longer-running, exhaustive small programs)
mix test test/pylixir/specialization_property_test.exs

# Manual sanity check — pick a small fixture, confirm specialization
mix run -e 'IO.puts Pylixir.transpile(File.read!("test/fixtures/python/01_fibonacci.py"))'
# Expected: arithmetic on n becomes Kernel.+ / -, py_add / py_sub not in helpers section.
```

Definition of done for the whole plan: average transpile size across
the fixture corpus drops by ≥15% with zero stdout-diff regressions,
zero eval-bucket regressions, and zero `mix test` failures.
