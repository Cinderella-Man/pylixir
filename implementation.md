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
                    runtime_statements, known_functions}
                 │  Pylixir.Context.new(known_functions)
                 ▼
        Pylixir.Converter.convert(module_ast, ctx, analysis)
                 │  recursive walk; per-node dispatch
                 ▼
        Elixir AST  (Macro.t() tuples)
                 │  Pylixir.Formatter.format/1
                 │   = Macro.to_string ▸ Code.format_string! ▸ iodata→binary
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
optional `lineno`/`col_offset`, and node-type-specific fields.

We shell out rather than embed because Python 3.14 is the source of truth
for "what is valid Python 3 AST". Tracking that ourselves would be a
permanent maintenance tax. Cost: a `System.cmd` per transpile (slow).
Pylixir's own unit tests bypass it by building AST maps by hand
(`%{"_type" => "Constant", "value" => 5}` etc.).

---

## Two pre-passes before the recursive walk

### `Pylixir.ModuleAnalysis.analyze/1`

Single pass over the `Module.body` list. Partitions every top-level
statement into one of three buckets:

1. **Module attrs** — `x = <literal>` where `x` is never reassigned,
   never `+=`-ed, never `obj[i] = `-ed downstream. These become
   `@var_x <literal>` at the top of the generated module.
2. **Function defs** — top-level `def f(...)` becomes a top-level `defp`.
3. **Runtime statements** — everything else, in original order. Lands in
   `py_main`'s body.

The mutation scan is the load-bearing bit. A literal `Assign` that *was*
mutated downstream gets demoted to a runtime statement, otherwise the
generated code would assign to `@var_x` (illegal — module attributes are
compile-time constants).

Also produces `known_functions`, the set of top-level `def` names, so a
forward call (`f()` defined later in the same module body) resolves.

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
├── context.ex                # %Pylixir.Context{} struct (12 fields)
├── module_analysis.ex        # the mutation-scan + partition pre-pass
├── loop_analysis.ex          # per-loop assigned/referenced var scan
├── naming.ex                 # Python identifier → Elixir identifier
├── builtins.ex               # Python's implicit-global functions
├── stdlib.ex                 # `import <mod>` registry (behaviour + map)
├── stdlib/
│   ├── math.ex               # @behaviour Pylixir.Stdlib for `math`
│   └── sys.ex                # @behaviour Pylixir.Stdlib for `sys`
├── nodes/                    # one file per Python-AST-node group
│   ├── comprehension.ex
│   ├── compare.ex
│   ├── if_stmt.ex
│   ├── loop.ex               # For + While + Break + Continue
│   ├── functions.ex          # FunctionDef + nested + Lambda
│   ├── mutations.ex          # statement-context `.append`/`.sort`/…
│   └── attribute_methods.ex  # ducktyped instance methods
├── lowering.ex               # shared result type + dispatch helper
├── control_flow.ex           # throw/catch shapes (return/break/continue/exit)
├── ast/
│   ├── walk.ex               # scope-aware pre-order traversal
│   ├── trivial.ex            # "safe to duplicate?" predicate
│   └── bool_returning.ex     # "lowers to a boolean?" predicate
├── runtime_helpers.ex        # py_*, truthy? — spliced into every output
├── helpers_codegen.ex        # reads runtime_helpers.ex at compile time
├── formatter.ex              # final Macro.to_string → format step
└── errors.ex                 # UnsupportedNodeError, PythonParseError
```

Mental model: **the node modules and stdlib modules are leaves; Converter
is the trunk; everything else is utility.**

---

## The output shape

```elixir
defmodule TranslatedCode do
  # ─── Helpers (spliced verbatim from RuntimeHelpers) ───
  def truthy?(nil), do: false
  # …~30 helpers: py_add, py_sub, py_int, py_str, py_len, py_input, …

  # ─── Module attributes (literal Assigns never mutated) ───
  @var_PI 3.14
  @var_COLORS ["red", "green"]

  # ─── Top-level functions ───
  defp greet(var_name) do
    # body...
  end

  # ─── While helpers (accumulated during conversion) ───
  defp while_0(acc1, acc2), do: cond do test -> while_0(...) ; true -> {acc1, acc2} end

  # ─── Entry point ───
  def py_main do
    try do
      # runtime statements in original order
    catch
      :throw, {:pylixir_exit, code} -> code
    end
  end
end

TranslatedCode.py_main()
```

`py_main` is the only `def` (vs `defp`) function. Its name is fixed; the
`py_*` prefix is reserved by Pylixir's Naming rules so it never collides
with a user's `def py_main`.

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

These were one option for unification (a single behaviour for
everything); the conscious choice was to keep them as two siblings.
See the moduledocs for the reasoning. The deletion test: if you forced
them under one shape, the callback would have to handle two
structurally different inputs and the simpler call-site would pay for
the complex one.

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

`py_*` and `var_*` are Pylixir's reserved prefixes — a Python
identifier matching either is *rejected* at translation time
(`Pylixir.Naming.reserved_prefix?/1`).

### 2. Python's truthiness differs from Elixir's

Python: `0`, `""`, `[]`, `{}`, `None` are all falsy. Elixir: only
`nil` and `false` are. So an `if x:` in Python isn't `if x do` in
Elixir — it's `if truthy?(x) do`.

`truthy?/1` is a runtime helper with clauses for every Python-falsy
shape. `Pylixir.Converter.convert_test/2` wraps every test expression
in `truthy?(…)`. The optimisation: `Pylixir.AST.BoolReturning` is a
predicate identifying expressions that *provably* already lower to a
boolean (currently only `Compare` nodes). When it returns true, the
wrap is skipped.

False-positives in that predicate would silently miscompile Python's
semantics; false-negatives are just verbose. Hence the conservative
ruleset.

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
single tail-position `return` doesn't get the try/catch wrapper (the
last expression already returns its value). Any other shape — two
returns, or one early return — wraps.

`break`/`continue` wraps are *also* conditional: the enclosing loop
walks its own body for the relevant node type before deciding to wrap.
Loops that don't contain `break` get no break-catch overhead.

All four throw/catch shapes live in `Pylixir.ControlFlow`'s `throw_*`
and `catch_*` constructors so emitters and catchers can't desync —
historically the atoms were scattered across ~10 sites.

---

## Loops are the most interesting lowering

`Nodes.Loop` picks one of four shapes per for-loop:

1. **`Enum.each`** — no assigned vars threaded, just side-effecting body
   (most common with bare `print`-loops).
2. **`Enum.reduce` with single accumulator** — body assigns one var that
   carries between iterations. The whole loop becomes
   `x = Enum.reduce(iter, initial_x, fn elem, x -> ... ; x end)`.
3. **`Enum.reduce` with tuple accumulator** — body assigns 2+ vars.
   Tuple pattern threads them.
4. (For *while* loops only) **Tail-recursive helper** — a `defp
   while_<n>(acc1, acc2, ro1)` accumulated onto `Context.while_helpers`
   and spliced into the wrapper module. The cond clause is the test;
   the recursive call is the iteration step.

Read-only variables (referenced in body but not assigned to, and bound
in the outer scope) get passed through unchanged in the while case.

Tradeoffs: a body that "threads" a dozen vars produces a verbose tuple
shape. Python's `for x in xs: total += x; count += 1; latest = x`
becomes `{total, count, latest} = Enum.reduce(...)`. It's correct but
not idiomatic Elixir. We accept this — the alternative is the
unreliable-by-construction option of trying to detect "this loop is
actually a fold" cases.

---

## If/elif/else

Three shapes:

- **`if x:`** alone → plain `if test do ... end`.
- **`if x: ... else: ...`** → plain `if test do ... else ... end`.
- **`if x: ... elif y: ... else: ...`** chain → collapses to one `cond
  do test1 -> ... ; test2 -> ... ; true -> ... end`. (Nested `if`s
  would also work but `cond` is the more direct lowering and what
  Python's `if/elif/else` actually means semantically.)

If any branch *assigns* a variable that's read after the if, the whole
expression evaluates to a **state tuple**: `{x, y} = if/cond do {x_a,
y_a} else {x_b, y_b} end`. The else branch always exists in the
emitted code, even if Python didn't have one, because Elixir's `if`
without `else` returns `nil` — which would unbind the state.

---

## Helpers (`RuntimeHelpers` + `HelpersCodegen`)

Helpers are public `def`s living in `Pylixir.RuntimeHelpers` between
two sentinel comments (`# --- HELPERS START ---` /
`# --- HELPERS END ---`).

`Pylixir.HelpersCodegen` reads `runtime_helpers.ex` at *Pylixir's own
compile time* (via `@external_resource` + `File.read!`), slices the
sentinel block, parses it to AST nodes, and exposes `helpers_ast/0`.
The Module clause of `Converter` splices that list into the
`TranslatedCode` body before everything else.

The compile-time-baked `@helpers_source` means a generated module is
truly self-contained: it doesn't `import Pylixir.RuntimeHelpers` at
runtime; it owns its own copy of every helper. Compile-time linkage to
the source file (via `@external_resource`) means changing a helper
forces Pylixir to rebuild.

**Linkage check:** `helper_names/0` exposes `{name, arity}` pairs.
`test/pylixir/helpers_linkage_test.exs` parses the source of every
Lowering producer (Builtins, every Stdlib impl, Converter,
node modules) and asserts every `{:py_*, [], _}` literal it emits
resolves to a real helper. Typos and renames die in the test suite
rather than in user code.

Reason helpers are `def` not `defp`: every output module imports them
all, most of which won't be called. Unused private functions warn;
unused public ones don't.

---

## Where to extend

| Goal | Where |
|---|---|
| Support a new Python **operator** | `Converter` operator-emission section, or a clause in the relevant node module |
| Support a new **builtin** function | `Pylixir.Builtins.emit/3` — add a clause; add to `@supported`; if it's safe to use as a HOF, add to `@unary_capturable` too |
| Support a new **stdlib module** | New file `lib/pylixir/stdlib/<name>.ex` implementing `Pylixir.Stdlib`; add to `@implementations` map. |
| Support a new **instance method** (`.foo()`) | `Pylixir.Nodes.AttributeMethods.do_dispatch/5` clause |
| Add a new **runtime helper** (`py_xyz/N`) | Add a `def` in `RuntimeHelpers` between the sentinels. Linkage test catches forgotten references. |
| New **AST node type** Pylixir doesn't yet translate | New `Pylixir.Nodes.<X>` module + a `convert/2` clause delegating to it |
| New **control-flow construct** that needs throw/catch | Add `throw_<x>/1` + `catch_<x>/2` in `Pylixir.ControlFlow`; everyone emits/catches through the constructors |

Each path is one-file plus one entry in a registry/dispatch map. No
edits across the whole codebase.

---

## Test layout

```
test/pylixir/
├── pylixir_test.exs                # top-level transpile() smoke + bug repros
├── transpile_test.exs              # end-to-end via shell-out to python3.14
├── converter_test.exs              # cross-cutting converter behaviour
├── context_test.exs                # the %Context{} struct
├── module_analysis_test.exs        # the mutation-scan pre-pass
├── loop_analysis_test.exs          # per-loop var scan
├── naming_test.exs                 # collision rewriting
├── lowering_test.exs               # the {:ok|:error|:no_clause} dispatch
├── control_flow_test.exs           # throw/catch protocol shapes
├── stdlib_test.exs                 # registry contract + Builtins shape
├── helpers_codegen_test.exs        # sentinel slicing + def-AST shape
├── helpers_linkage_test.exs        # every py_* reference resolves
├── runtime_helpers_test.exs        # call helpers directly
├── formatter_test.exs              # Macro→source formatting
├── transpile_helpers_test.exs      # the compile-and-eval test seam
├── golden_corpus_test.exs          # single test, walks all fixtures
├── integration_test.exs            # bigger end-to-end scenarios
├── nodes/                          # mirror of lib/pylixir/nodes/
│   ├── for_test.exs                  (note: tests existed before the
│   ├── while_test.exs                 corresponding lib/ split — the
│   ├── comprehension_test.exs         test/lib mirror was *planned*
│   ├── function_def_test.exs          first)
│   ├── if_test.exs
│   ├── assign_test.exs
│   ├── aug_assign_test.exs
│   ├── compare_test.exs
│   ├── attribute_dispatch_test.exs
│   ├── …
│   └── unsupported_coverage_test.exs # direct raise paths
└── stdlib/
    └── sys_test.exs
test/fixtures/python/
└── NN_<name>.py                    # 30 golden fixtures
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

## Known limitations (intentional, in MVP)

- **No `class`** — Python OO unsupported. Pylixir's `UnsupportedNodeError`
  fires on `ClassDef`. Users are expected to model state as maps and
  behaviour as functions.
- **No `try/except`, no `raise`** — only runtime helpers raise. Errors
  propagate as BEAM exceptions.
- **No generators (`yield`)** — would require continuation support.
- **No `match`/`case`** (PEP 634) — too new and structurally different.
- **Method dispatch is ducktyped** — `Nodes.AttributeMethods` assumes the
  call site knows the right type. Wrong type at runtime → crash.
- **Float `inf`/`nan` rejected at translation time** — Elixir has no
  IEEE-754 inf/nan equivalent on its native float type.
- **No tree-shaking** — every output module includes every helper. A few
  KB of dead `defs` per module. Not a correctness issue; would be a
  tidy follow-up.

---

## Reading the code in order

If you've never touched this codebase before, this is the order I'd
suggest:

1. **`lib/pylixir.ex`** — 80 lines. The entire public API. Read first.
2. **`lib/pylixir/context.ex`** — the struct that gets threaded
   everywhere. Internalising its field set makes Converter readable.
3. **`lib/pylixir/converter.ex`**, the `convert/2` clauses only
   (~470 lines of dispatch). The bottom half is the cross-node helpers.
4. **`lib/pylixir/nodes/comprehension.ex`** — smallest node module, shows
   the delegation pattern in 100 lines.
5. **`lib/pylixir/builtins.ex`** — shows the `Lowering.result()` shape
   exhaustively.
6. **`lib/pylixir/stdlib.ex`** and the two impls under `stdlib/`. The
   `@behaviour` shape.
7. **`lib/pylixir/runtime_helpers.ex`** between the sentinels — the
   spliced runtime. Reading these makes the generated output legible.
8. **Pick a node module that interests you** — `loop.ex` if you like
   tricky lowerings, `functions.ex` for the return-wrap heuristic,
   `if_stmt.ex` for state-tuple threading.

A new Python construct, from scratch: write a fixture under
`test/fixtures/python/` first (just CPython behaviour), let the
golden-corpus test fail loudly to tell you which node type Pylixir
rejects, then either add a clause to an existing node module or stand
up a new one.
