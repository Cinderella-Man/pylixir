# Pylixir — Implementation Walkthrough

This file is the architecture tour. For domain-vocabulary definitions see
[CONTEXT.md](CONTEXT.md); for the original spec see [docs/rfc.md](docs/rfc.md).
Assumed knowledge: Elixir (you can read `Macro.t()` tuples), close to zero
Python.

---

## What Pylixir does, in one paragraph

Pylixir is a **source-to-source compiler**: it takes a Python program as a
string, and returns a self-contained Elixir source string that, when
compiled and run on the BEAM, behaves like the original Python program.
"Self-contained" is load-bearing — the output `defmodule TranslatedCode`
has *no runtime dependency on Pylixir itself*. Every helper it needs is
spliced into the module verbatim. You could email someone the generated
.ex file and they'd be able to compile and run it without ever hearing
of Pylixir.

---

## The pipeline (end-to-end)

```
Python source  ──┐
                 │  python3.14 priv/python/serialize.py    (shell out)
                 ▼
        JSON AST envelope                                  (text)
                 │  Jason.decode!
                 ▼
        Python AST map  { "_type" => "Module", "body" => [...] }
                 │  Pylixir.ModuleAnalysis.analyze/1       (single pre-pass)
                 ▼
        analysis = {module_attrs, function_defs,
                    runtime_statements, known_functions,
                    module_doc}
                 │  Pylixir.Context.new(known_functions)
                 ▼
        Pylixir.Converter.convert(module_ast, ctx, analysis)
                 │  recursive walk; per-node dispatch
                 ▼
        Elixir AST  (Macro.t() tuples)
                 │  Pylixir.Formatter.format/1
                 ▼
        Elixir source string  "defmodule TranslatedCode do ... end"
```

`Pylixir.transpile/1` runs the full chain. `Pylixir.to_source/1` skips the
shell-out and starts from an AST map (this is the seam most tests use —
no python3.14 required).

---

## What the Python serializer does

Python's stdlib has `ast.parse`. The custom `priv/python/serialize.py`
script imports it, walks the resulting tree, and prints one JSON object
per top-level `ast.parse` invocation. Each AST node becomes a JSON map
with a `_type` discriminator (`"Module"`, `"Assign"`, `"BinOp"`, …),
optional `lineno`/`col_offset`, and node-type-specific fields. `ctx`
(Load/Store/Del) is preserved on Name nodes — referenced-name analysis
relies on it.

We shell out rather than embed because Python 3.14 is the source of truth
for "what is valid Python 3 AST". Tracking that ourselves would be a
permanent maintenance tax. Cost: a `System.cmd` per transpile (slow).
Pylixir's own unit tests bypass it by building AST maps by hand.

---

## Two pre-passes before the recursive walk

### `Pylixir.ModuleAnalysis.analyze/1`

Single pass over the `Module.body` list. Partitions every top-level
statement into one of three buckets:

1. **Module attrs** — `x = <foldable_literal>` (constants and arithmetic
   over them, via `Pylixir.LiteralFold`) where `x` is never reassigned,
   never mutated downstream, **and is referenced somewhere**. Become
   `@var_x <value>` at the top. Names never read get demoted back to
   runtime statements (avoids Elixir's "module attribute set but never
   used" error).
2. **Function defs** — top-level `def f(...)` becomes a top-level **`def`**
   (public). Switched from `defp` so `@doc` from a Python docstring
   attaches cleanly and `apply(__MODULE__, :f, args)` (used by the
   star-unpack-call path) can reach the function. Functions whose body
   references mutable top-level state (e.g. a dict populated by a runtime
   loop) get *demoted* into runtime statements at their original
   position; they emit as `name = fn ... end` closures that can see
   py_main's scope. Demotion is a fix-point — a function that calls an
   already-demoted function is itself demoted.
3. **Runtime statements** — everything else, in original order. Lands in
   `py_main`'s body.

Also extracts the module-level docstring (first bare-string statement
when followed by other statements) → `analysis.module_doc` → `@moduledoc`.

Mutation detection covers Assigns, AugAssigns, statement-mutation methods
(`xs.append(x)`, `xs.sort()`), subscript writes, for-loop targets,
capture-return Assigns (`x = coll.pop()`), and `heapq.X(h, …)` calls
(recognized via `Pylixir.Stdlib.Heapq.statement_mutation_call/2`).

### `Pylixir.LoopAnalysis.analyze/1`

Per-loop pass: walks a `For.body` or `While.body` and returns
`{assigned_vars, referenced_vars}`. The loop emitter (`Nodes.Loop`)
reads this to decide its lowering strategy — `Enum.each` if nothing's
threaded, `Enum.reduce` if one var is threaded, tuple-reduce if many.

Both passes use `Pylixir.AST.Walk.walk_scope/3`, a pre-order tree walker
that **does not descend into nested-scope nodes** (FunctionDef, Lambda,
ClassDef, the four Comp types). That matches Python's lexical-scope
rules: a name assigned inside a nested function doesn't leak.

---

## The Converter

`Pylixir.Converter.convert/2` is the dispatcher. It pattern-matches on
`node["_type"]` and either:

- emits Elixir AST inline (small node types like `Constant`, `Name`,
  `List`, `Tuple`), or
- delegates one line to a `Pylixir.Nodes.<X>` module (every node type
  whose lowering is more than ~10 lines).

Every clause returns `{elixir_ast, updated_context}`. The context is
threaded through every recursive call. This is the whole API surface —
once you grasp `convert/2`'s shape, everything else slots in.

Converter also owns the **shared mechanics** that node modules call
back into: `convert_each/2` (map convert over a list of nodes,
threading context), `convert_keywords/2`, `convert_loop_target/2`,
`convert_test/2`, `bind_name/2`, `body_to_block/1`,
`tuple_pattern/1`, `next_temp/1`, `maybe_temp_bind/2`,
`var_bound?/2`, `name_in_scope?/2`. These are `def @doc false` —
internal API for the node modules, not user API.

---

## Code layout

```
lib/pylixir/
├── pylixir.ex                # transpile/1, to_source/1, python_ast/1
├── converter.ex              # convert/2 dispatcher + shared mechanics
├── context.ex                # %Pylixir.Context{} struct
├── module_analysis.ex        # mutation-scan, attr-promotion, closure demotion
├── loop_analysis.ex          # per-loop assigned/referenced var scan
├── literal_fold.ex           # compile-time eval of literal arithmetic
├── naming.ex                 # Python identifier → Elixir identifier
├── builtins.ex               # Python's implicit-global functions
├── stdlib.ex                 # `import <mod>` registry (behaviour + map + capture/2)
├── stdlib/
│   ├── bisect.ex             # `bisect.bisect_left/right` (+ 4-arg form)
│   ├── collections.ex        # Counter / defaultdict / deque routing
│   ├── heapq.ex              # call/4 + statement_mutation_call/2 + capture_return_call/2
│   ├── itertools.ex          # combinations, permutations
│   ├── math.ex               # math.* (sqrt, gcd, comb, hypot, factorial, log(x,base), …)
│   ├── re.ex                 # findall, search, match, sub, split
│   └── sys.ex                # sys.stdin / argv / maxsize / setrecursionlimit
├── nodes/                    # one file per Python-AST-node group
│   ├── assign.ex             # Assign + tuple/list destructure + starred + nested-subscript
│   ├── attribute_methods.ex  # ducktyped instance methods (str/dict/set/int)
│   ├── compare.ex            # single + chained comparisons
│   ├── comprehension.ex      # list/set/dict/generator comps
│   ├── f_string.ex           # JoinedStr + FormattedValue + format-spec extraction
│   ├── functions.ex          # FunctionDef + nested + Lambda + decorator handling
│   ├── if_stmt.ex            # if/elif/else with state-tuple threading
│   ├── loop.ex               # For + While + Break + Continue + for/else
│   └── mutations.ex          # statement-context `.append`/`.sort`/…
├── lowering.ex               # shared {:ok|:error|:no_clause} dispatch helper
├── control_flow.ex           # throw/catch shapes (return/break/continue/exit)
├── mutable_module_dict.ex    # Process.get/put adapter for module-level mutable bindings
├── type_infer.ex             # lattice, infer_expr/2, bind/demote, heap-typing
├── type_infer/
│   ├── builtin_signatures.ex # return-type tables for Python builtins/methods + HOF arg recovery
│   ├── signatures.ex         # bounded fixed-point pass producing Context.fn_signatures
│   └── isinstance_narrowing.ex # `if isinstance(x, T):` → narrowed ctx.types[x]
├── ast/
│   ├── walk.ex               # scope-aware pre-order traversal
│   ├── trivial.ex            # "safe to duplicate?" predicate
│   └── bool_returning.ex     # "lowers to a boolean?" predicate
├── runtime_helpers.ex        # core py_* (arith, collection, conv, string, heapq, bisect, …)
├── runtime_helpers/          # per-topic submodules also spliced into output
│   ├── format.ex             # py_format_value + parse_format_spec + center_pad
│   ├── math_ext.ex           # py_math_comb/factorial/hypot/pow_mod
│   └── regex.ex              # py_re_findall/search/match/sub/split
├── helpers_codegen.ex        # reads all helpers files at compile time + slices
├── formatter.ex              # final Macro.to_string → format step
└── errors.ex                 # UnsupportedNodeError, PythonParseError
```

Mental model: **node modules and stdlib modules are leaves; Converter
is the trunk; the runtime_helpers tree is splice material; everything
else is utility.**

---

## The output shape

```elixir
defmodule TranslatedCode do
  @moduledoc "Module docstring (when present, extracted by ModuleAnalysis)"

  # ─── Helpers (spliced verbatim from RuntimeHelpers + submodules) ───
  def truthy?(nil), do: false
  # …~60 helpers: py_add, py_sub, py_int, py_str, py_len, py_format_value, py_re_*, …

  # ─── Module attributes (literal Assigns never mutated AND referenced) ───
  @var_PI 3.14
  @var_COLORS ["red", "green"]

  # ─── Top-level functions (def, not defp — see ModuleAnalysis notes) ───
  @doc "Function docstring promoted from Python's PEP 257 string"
  def greet(var_name) do
    # body...
  end

  # ─── While helpers (accumulated during conversion) ───
  defp while_0(acc1, acc2), do: cond do test -> while_0(...) ; true -> {acc1, acc2} end

  # ─── Entry point ───
  def py_main do
    try do
      # runtime statements in original order
      # (includes demoted-to-closure FunctionDefs and from-import alias bindings)
    catch
      :throw, {:pylixir_exit, code} -> code
    end
  end
end

TranslatedCode.py_main()
```

`py_main` is the entry point. The `py_*` prefix is reserved by Pylixir's
Naming rules so it never collides with a user's `def py_main`.

The trailing `TranslatedCode.py_main()` call is what makes the file
"runnable" — `mix run` it and `py_main` fires.

---

## Two-track lowering: `Lowering` vs `Nodes.AttributeMethods`

Pylixir handles two structurally different "translate this call"
problems:

1. **Namespace-keyed** (`int(5)`, `math.sqrt(4)`, `sys.stdin.read()`) —
   the "key" is a known name or path at codegen time. Two surfaces:
   `Pylixir.Builtins` for Python's implicit globals, `Pylixir.Stdlib`
   for imported modules. Both return a `Pylixir.Lowering.result()`
   tuple (`{:ok, ast} | {:error, hint} | :no_clause`), and one helper
   — `Lowering.dispatch/4` — converts that to either `{ast, ctx}` or
   raises `UnsupportedNodeError`. They share the *return contract*, not
   a behaviour.

2. **Target-keyed** (`x.lower()`, `xs.append(y)`) — keyed on
   `(method_name, target_ast)`. The target's type isn't known
   statically; Pylixir trusts the Python source ("`.lower` is only ever
   called on a string"). `Pylixir.Nodes.AttributeMethods.dispatch/5`
   owns this.

---

## The Stdlib registry — three callbacks

`@behaviour Pylixir.Stdlib` requires three callbacks. Adding a new
stdlib = one new file + one entry in `@implementations`. No converter
edit.

| Callback | Purpose | Example |
|---|---|---|
| `attribute/2` | `mod.attr` access | `math.pi` → `:math.pi()` |
| `call/4` | `mod.fn(args)` call | `math.sqrt(x)` → `:math.sqrt(x)` |
| `import_binding/1` | RHS for `from <mod> import <name>` | `bisect_left` → `&py_bisect_left/2` |

`import_binding/1` returns one of:

- a **value** AST (`{:ok, {{:., [], [{:__aliases__, [], [:System]}, :argv]}, [], []}}` for `sys.argv`),
- a **`&capture/N`** built via `Pylixir.Stdlib.capture/2` (function-shaped imports — `bisect_left`, `combinations`),
- a **sentinel `nil`** for names recognised at the call site via `Context.stdlib_aliases` (heapq's `heappush`/`heappop`/`heapify`, where the call gets rewritten back to `heapq.X(…)` form so the rebind machinery fires).

After binding, the converter records `context.stdlib_aliases[alias] =
{mod, name}` so a later `bare_name(a, 3)` call can route through the
stdlib's `call/4` when the captured arity doesn't match.

Currently registered: `bisect`, `collections`, `heapq`, `itertools`,
`math`, `re`, `sys`. (functools is handled by a small no-op
ImportFrom clause in Converter — it's not a registry member because
it has no `call/4` lowerings.)

### Stdlib modules can own shared recognizers

`Pylixir.Stdlib.Heapq` exposes `statement_mutation_call/2` and
`capture_return_call/2` — recognizers for `heapq.heappush(h, x)` /
`heapq.heappop(h)` (and the bare-Name aliased forms). Four sites use
them: Converter's Expr clause, Nodes.Assign's capture-return path,
ModuleAnalysis's mutation tracker, LoopAnalysis's accumulator threader.
Each site emits its own rebind shape — only the *recognition* is
shared. Without this, the heapq pattern would be duplicated four times.

---

## Three hard problems and how Pylixir solves them

### 1. Identifier collisions (`Pylixir.Naming`)

Python permits identifiers that Elixir's parser rejects (`if`,
`length`, `W`) or that would silently shadow important things
(`length = 5` would shadow `Kernel.length/1`). Four categories of
collision get rewritten with a `var_` prefix:

1. **Hard keywords** (`when`, `do`, `end`, …) — parser rejects.
2. **Special forms** (`if`, `case`, `cond`, …) — would shadow.
3. **Kernel auto-imports** (`length`, `hd`, `is_integer`, …) — derived
   from `Kernel.__info__/1` at Pylixir's compile time.
4. **Alias-shaped** — any identifier whose first character is ASCII
   `A`–`Z`. Elixir parses these as module aliases, not variables. So
   Python's `W, H = (1, 2)` becomes `{var_W, var_H} = {1, 2}`.

A user identifier starting with `var_` (legal Python, e.g. `var_type`)
gets an additional `usr_` prefix on emission (`usr_var_type`) to avoid
colliding with the rewrite of Python's `type` → `var_type`. `py_*` is
still outright rejected — it's the reserved runtime-helper namespace.

### 2. Python's truthiness differs from Elixir's

Python: `0`, `""`, `[]`, `{}`, `None` are all falsy. Elixir: only
`nil` and `false` are. So an `if x:` in Python isn't `if x do` in
Elixir — it's `if truthy?(x) do`.

`truthy?/1` is a runtime helper with clauses for every Python-falsy
shape. `Pylixir.Converter.convert_test/2` wraps every test expression
in `truthy?(…)`. Two short-circuits skip the wrap:

1. **AST-shape**: `Pylixir.AST.BoolReturning` recognises `Compare`
   nodes — they always lower to a boolean regardless of operand types.
2. **Type-aware** (S1): `Pylixir.TypeInfer.infer_expr/2` reports the
   inferred lattice type of the test; if it's exactly `{:bool}`, the
   wrap drops. Catches `BoolOp` of two `is_X?` calls, `isinstance` /
   `callable` / `hasattr` / `issubclass` (all return `{:bool}` per
   `TypeInfer.BuiltinSignatures`), and `Name` references bound from a
   typed expression. Soundness: union types containing `{:bool}` stay
   wrapped — Python's `0-is-falsy` semantics would diverge.

`Constant`-boolean tests (`while True:`) deliberately keep the wrap
even though they're trivially `{:bool}` — emitting bare `true` as a
`cond` clause head triggers Elixir's "this clause in cond will always
match" warning when paired with the while-emitter's fallback clause.

False-positives in either path would silently miscompile Python's
semantics; false-negatives are just verbose. Hence the conservative
rulesets.

### 3. Python's single-evaluation semantics

In Python, `a < b() < c` evaluates `b()` *once* even though it appears
as both right-of-`<` and left-of-`<`. The lowering target,
`a < b() && b() < c`, evaluates it twice — wrong if `b` has side
effects.

`Pylixir.AST.Trivial.trivial?/1` identifies expressions that *can* be
safely re-emitted at multiple call sites (`Constant`, `Name`,
`Attribute` chains rooted at a `Name`). Anything else is bound to a
`py_tmp_<n>` temp via `Pylixir.Converter.maybe_temp_bind/2` before
being referenced again. Same monotonic counter is shared across all
single-eval sites in one function, so `py_tmp_0` and `py_tmp_3` never
collide.

Same predicate-asymmetry as truthiness: false-positives miscompile;
false-negatives are merely verbose.

---

## Type inference (`Pylixir.TypeInfer`)

A static type-inference pass threads through conversion to monomorphise
runtime helpers when types are statically knowable. Three submodules
under `Pylixir.TypeInfer`; the main module owns the lattice and walker.

### The lattice

```
:any | :bottom | {:int} | {:int_lit_nonneg} | {:float} | {:bool}
     | {:str} | {:none} | {:list, t} | {:tuple, [t] | :any_arity}
     | {:dict, t, t} | {:set} | {:union, MapSet.t(t)}
```

`{:int_lit_nonneg}` is a refinement subtype of `{:int}` used only by
the `String.duplicate("x", n) / List.duplicate(xs, n)` specialisations
— Python's `"x" * -1 == ""` but Elixir's would raise. `lub/2` joins
types via a numeric-tower-aware rule (int + float → float) with bool
deliberately *not* folded in (Python's `True + 1 == 2` but Elixir's
`true + 1` raises).

`:bottom` is the internal "no information yet" identity; the public
`TypeInfer.demote_bottom/1` converts it to `:any` so consumers never
see `:bottom`.

### The walker (`infer_expr/2`)

Read-only walk over the Python AST. Returns the inferred lattice
type of the node. Never mutates `Context`. Routes Call nodes to
`TypeInfer.BuiltinSignatures.return_type/3` (for builtin-name calls)
or `BuiltinSignatures.method_return_type/1` (for attribute-method
calls).

Mutation (`bind`, `bind_pattern`, `demote`) happens at the *conversion
clause that follows the inference* — e.g. the `Assign` node module
calls `TypeInfer.bind_pattern/3` after `infer_expr/2` on the RHS. The
read-only/mutating split keeps the inference walker reasoning local.

### The fixed point (`Pylixir.TypeInfer.Signatures`)

Once before per-statement conversion, `Signatures.infer/3` runs a
bounded fixed-point pass (≤5 rounds) over top-level user `def`s to
populate `Context.fn_signatures` with `{param_types, return_type}`.
External call sites pin param types via `lub`; recursive in-body
self-calls contribute `:bottom` (excluded from the lub) so iteration
actually converges. Each round overrides the in-flight function's
signature to `{params, :bottom}` so its recursive calls return
`:bottom` (which lubs cleanly with the base-case return type).

### Static knowledge (`Pylixir.TypeInfer.BuiltinSignatures`)

Two hardcoded lookup tables — Python builtin name → return type
(`len → {:int_lit_nonneg}`, `range → {:list, {:int}}`,
`isinstance → {:bool}`) and Python method name → return type
(`.startswith → {:bool}`, `.split → {:list, {:str}}`). Plus
`function_return_type/2`, which recovers a function-valued AST node's
return type for HOF stdlib inference (`map(f, xs) →
{:list, function_return_type(f)}` when `f` is a typed `Name` or a
`Lambda`).

### Branch narrowing (`Pylixir.TypeInfer.IsinstanceNarrowing`)

`if isinstance(x, T):` narrows `ctx.types[x]` to `T`'s lattice type
inside the body branch. Recognises bare `Name("int" | "str" | …)`
specs and `Tuple` specs (lub of per-element types — Python's
`isinstance(x, (int, str))`). Called from `Pylixir.Converter`'s
`If` clause.

### Specialisation sites

The inferred types are consumed at emit sites that have both a
specialised AST shape (when types are known) and a polymorphic
fallback (when they're `:any`):

- `Pylixir.Converter.bin_op_ast/6` — `int+int → Kernel.+`,
  `str+str → Kernel.<>`, `list+list → Kernel.++`, etc.
- `Pylixir.Nodes.Compare.pair_ast/5` — `x in [list]` → `Kernel.in/2`,
  `x in MapSet` → `MapSet.member?`, etc.
- `Pylixir.Builtins.emit/4` — typed `len/int/str/bool`, `print` arg
  formatting, container constructors.
- `Pylixir.Nodes.FString` — drop `py_str` for `{:str}` segments,
  emit `Integer.to_string` for `{:int}`.
- Iter-consumer sites (`for`, `sorted`, `map`, `filter`, …) — drop
  `py_iter_to_list` wrapping when the iterable is statically a list.

See `docs/02_type-inference-monomorphization.md` for the full design,
PRs S0–S5 and T6–T8 for the rollout, and `docs/03_helper-preamble-slimming.md`
for the follow-on slimming work.

---

## Control flow via throw/catch (`Pylixir.ControlFlow`)

Four Python early-exit constructs lower to Erlang throws caught by an
enclosing try/catch:

| Python | Lowered throw | Caught by |
|---|---|---|
| `return value` | `{:pylixir_return, value}` | function body wrapper (only when `Context.return_mode == :wrapped`) |
| `break` | `{:pylixir_break, payload}` | enclosing loop |
| `continue` | `{:pylixir_continue, payload}` | enclosing loop iteration |
| `exit(code)` / `sys.exit(code)` | `{:pylixir_exit, code}` | py_main's wrapper |

The `:wrapped` return-mode decision is conservative: a function with a
single tail-position `return` doesn't get the try/catch wrapper.

`try/except/else/finally` is a type-agnostic minimal lowering: emits
Elixir's `try do … rescue _ -> … end` (the exception type and `as e`
binding are ignored — Pylixir doesn't model exception classes).
`finally` becomes `after`.

All throw/catch shapes live in `Pylixir.ControlFlow`'s `throw_*` and
`catch_*` constructors so emitters and catchers can't desync.

---

## Loops are the most interesting lowering

`Nodes.Loop` picks one of four shapes per for-loop:

1. **`Enum.each`** — no assigned vars threaded, just side-effecting body.
2. **`Enum.reduce` with single accumulator** — body assigns one var that
   carries between iterations.
3. **`Enum.reduce` with tuple accumulator** — body assigns 2+ vars.
4. (For *while* loops only) **Tail-recursive helper** — a `defp
   while_<n>(…)` accumulated onto `Context.while_helpers` and spliced
   into the wrapper module.

**for/else** wraps the reduce/each in a try producing `{state, broke?}`
— `{state, false}` on normal completion, `{payload, true}` on break.
Then `unless broke?, do: else_block`.

`range(start, stop)` lowers with explicit step `start..stop-1//1` so
empty ranges (`range(2, 2)`) produce `[]` instead of flipping to a
descending range.

---

## If/elif/else

Three shapes:

- **`if x:`** alone → plain `if test do ... end`.
- **`if x: ... else: ...`** → plain `if test do ... else ... end`.
- **`if x: ... elif y: ... else: ...`** chain → collapses to one `cond
  do test1 -> ... ; test2 -> ... ; true -> ... end`.

If any branch *assigns* a variable that's read after the if, the whole
expression evaluates to a **state tuple**. The else branch always
exists in the emitted code, even if Python didn't have one, because
Elixir's `if` without `else` returns `nil` — which would unbind the
state.

---

## Helpers (`RuntimeHelpers` + `HelpersCodegen`)

Helpers are public `def`s living between `# --- HELPERS START ---` /
`# --- HELPERS END ---` sentinels in **multiple files**:

- `lib/pylixir/runtime_helpers.ex` — core (arithmetic, collection
  access, type conversion, string ops, banker's rounding, heapq,
  bitwise/set polymorphism, itertools combinations/permutations, slice
  assignment, bisect, integer methods, input).
- `lib/pylixir/runtime_helpers/format.ex` — f-string format-spec parser.
- `lib/pylixir/runtime_helpers/regex.ex` — Python `re` runtime.
- `lib/pylixir/runtime_helpers/math_ext.ex` — `math.comb`/`factorial`/
  `hypot`/`pow_mod`.

`Pylixir.HelpersCodegen` reads each file at *Pylixir's own compile
time* (via `@external_resource` + `File.read!`), slices the sentinel
block in each, and concatenates them into `@helpers_source`. The
Module clause of `Converter` splices that into the `TranslatedCode`
body before everything else.

**Linkage check:** `helper_names/0` exposes `{name, arity}` pairs.
`test/pylixir/helpers_linkage_test.exs` parses the source of every
Lowering producer and asserts every `{:py_*, [], _}` literal resolves
to a real helper. Typos die in the test suite, not in user code.

Reason helpers are `def` not `defp`: every output module imports them
all, most of which won't be called. Unused private functions warn;
unused public ones don't.

---

## Where to extend

| Goal | Where |
|---|---|
| Support a new Python **operator** | `Converter` operator-emission section, or a clause in the relevant node module |
| Support a new **builtin** function | `Pylixir.Builtins.emit/3` — add a clause; add to `@supported`; if it's safe to use as a HOF, add to `@unary_capturable` too |
| Support a new **stdlib module** | New file `lib/pylixir/stdlib/<name>.ex` implementing `Pylixir.Stdlib` (3 callbacks: `attribute/2`, `call/4`, `import_binding/1`); add to `@implementations` map |
| Support a new **instance method** (`.foo()`) | `Pylixir.Nodes.AttributeMethods.do_dispatch/5` clause |
| Add a new **runtime helper** (`py_xyz/N`) | Add a `def` between the sentinels in `RuntimeHelpers` or a relevant submodule. Linkage test catches forgotten references. |
| Add a new **topic submodule** of helpers | New file under `lib/pylixir/runtime_helpers/`; add path to `@helper_files` in `HelpersCodegen` |
| New **AST node type** Pylixir doesn't yet translate | New `Pylixir.Nodes.<X>` module + a `convert/2` clause delegating to it |
| New **control-flow construct** that needs throw/catch | Add `throw_<x>/1` + `catch_<x>/2` in `Pylixir.ControlFlow`; everyone emits/catches through the constructors |

Each path is one-file plus one entry in a registry/dispatch map. No
edits across the whole codebase.

---

## Test layout

```
test/pylixir/
├── pylixir_test.exs                # top-level transpile() smoke + bug repros
├── converter_test.exs              # cross-cutting converter behaviour
├── context_test.exs                # the %Context{} struct
├── module_analysis_test.exs        # mutation-scan + attr promotion/demotion
├── loop_analysis_test.exs          # per-loop var scan
├── naming_test.exs                 # collision rewriting
├── lowering_test.exs               # the {:ok|:error|:no_clause} dispatch
├── control_flow_test.exs           # throw/catch protocol shapes
├── stdlib_test.exs                 # registry contract + Builtins shape
├── helpers_codegen_test.exs        # sentinel slicing + def-AST shape
├── helpers_linkage_test.exs        # every py_* reference resolves
├── runtime_helpers_test.exs        # call helpers directly
├── formatter_test.exs              # Macro→source formatting
├── integration_test.exs            # bigger end-to-end scenarios
├── golden_corpus_test.exs          # single test, walks all 94 fixtures
├── nodes/                          # mirror of lib/pylixir/nodes/
│   ├── assign_test.exs
│   ├── attribute_dispatch_test.exs
│   ├── aug_assign_test.exs
│   ├── compare_test.exs
│   ├── comprehension_test.exs
│   ├── for_test.exs
│   ├── function_def_test.exs
│   ├── if_test.exs
│   ├── while_test.exs
│   ├── …
│   └── unsupported_coverage_test.exs # direct raise paths
└── stdlib/
    ├── bisect_test.exs
    └── sys_test.exs
test/fixtures/python/
└── NN_<name>.py                    # 94 golden fixtures
```

Three test seams worth knowing:

1. **`Pylixir.TranspileHelpers.run_source/1`** — takes an already-emitted
   Elixir source string, compiles it into a uniquely-aliased
   `TranslatedCode_<N>` module, invokes `py_main`, captures stdout,
   returns `{source, value, stdout, diagnostics}`. The uniquification
   means `async: true` is safe.

2. **`Pylixir.TranspileHelpers.transpile_and_run/1`** — same, starting
   from an AST map. No python3.14 needed. Most unit tests use this.

3. **`Pylixir.GoldenCorpusTest`** — runs every `test/fixtures/python/*.py`
   under both CPython 3.14 and Pylixir and asserts stdouts match. Skips
   the whole test if python3.14 isn't on PATH. The fixtures double as
   end-to-end documentation of what Pylixir supports.

---

## Known limitations (intentional)

- **No `class`** — Python OO unsupported. `ClassDef` raises. Users are
  expected to model state as maps and behaviour as functions.
- **No generators (`yield`)** — would require continuation support.
- **No `match`/`case`** (PEP 634) — too new and structurally different.
- **No `raise`** — runtime helpers raise via Elixir; user-side `raise`
  isn't supported.
- **`try/except` is type-agnostic** — `except ValueError as e:` catches
  any exception and ignores `e` (Pylixir doesn't model exception
  classes). Good enough for "fall back on failure" patterns.
- **Method dispatch is ducktyped** — `Nodes.AttributeMethods` assumes
  the call site knows the right type. Wrong type at runtime → crash.
- **Float `inf`/`nan` rejected at translation time** — Elixir has no
  IEEE-754 inf/nan equivalent on its native float type.
- **`*args` on top-level defs only works via `apply/3` path** — bare
  star-unpack on closure-demoted defs is fine; bare star on stdlib
  builtins beyond `zip` falls back to a clear error message.
- **Heap internal representation differs** — Pylixir uses a sorted
  list; Python uses a binary-tree-as-array. `heappop` ordering matches;
  the raw heap layout doesn't (don't assert on `print(heap)`).
- **No tree-shaking** — every output module includes every helper. A
  few KB of dead `defs` per module.

---

## Reading the code in order

If you've never touched this codebase before:

1. **`lib/pylixir.ex`** — ~80 lines. The entire public API. Read first.
2. **`lib/pylixir/context.ex`** — the struct that gets threaded
   everywhere. Internalising its field set makes Converter readable.
3. **`lib/pylixir/converter.ex`**, the `convert/2` clauses only.
   The bottom half is the cross-node helpers.
4. **`lib/pylixir/nodes/comprehension.ex`** — smallest node module,
   shows the delegation pattern in 100 lines.
5. **`lib/pylixir/builtins.ex`** — shows the `Lowering.result()` shape
   exhaustively.
6. **`lib/pylixir/stdlib.ex`** and a small impl like `stdlib/bisect.ex`.
   The 3-callback behaviour shape.
7. **`lib/pylixir/runtime_helpers.ex`** between the sentinels — the
   spliced runtime. Reading these makes the generated output legible.
8. **Pick a node module that interests you** — `loop.ex` for tricky
   lowerings, `functions.ex` for the return-wrap heuristic, `if_stmt.ex`
   for state-tuple threading, `assign.ex` for the destructure zoo.

A new Python construct, from scratch: write a fixture under
`test/fixtures/python/` first (just CPython behaviour), let the
golden-corpus test fail loudly to tell you which node type Pylixir
rejects, then either add a clause to an existing node module or stand
up a new one.
