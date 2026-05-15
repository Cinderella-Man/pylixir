# Plan: pylixir — Python AST → Elixir transpiler (greenfield)

## Context

Repo is empty (`docs/rfc.md` only). RFC-001 v10 specifies an Elixir library:
`Pylixir.to_source/1` takes a Python AST as decoded-JSON map, returns Elixir source string. Optional `Pylixir.transpile/1` shells out to `python3` for convenience.

Local env: Elixir 1.19.5 / OTP 28 ✓ (RFC needs 1.19+/26+). Python 3.14.5 ✓ (RFC requires 3.14+). All fixtures generated on 3.14.5; CI pinned to 3.14.5; no version-skipping in any ticket.

Goal of this plan: ordered list of ~40 small tickets (≈ ½–1 day each), each shippable as its own PR. Tests live inline with each ticket. Each ticket lists the RFC section(s) it depends on plus the edge-case traps it must handle.

Output ordering follows §12 of the RFC but splits the fat steps. Helpers (`truthy?`, `py_add`, …) are introduced exactly when the first node needing them is implemented, then extended.

---

## Conventions

- Every ticket ends with `mix test` green + `mix format --check-formatted` green.
- **Converter signature is `convert(map(), Context.t()) :: {elixir_ast(), Context.t()}`** (already shipped in T03). Every node clause must thread context: receive a `Context`, return the *updated* `Context` alongside the emitted AST. Counters (`while_counter`, `compare_counter`), scopes, and `known_functions` all flow through this tuple. Call sites destructure: `{ast, ctx} = convert(child, ctx)`. Forgetting to thread is a silent bug — second `While` gets the same `while_<n>` name, nested chained-compare temps collide, scope frames leak.
- Generated output is **fully self-contained**: a single Elixir source string with helpers spliced in as `def` (public). Generated code never depends on Pylixir at runtime.
- **Helpers are `def`, not `defp`** — verified empirically: `@compile :nowarn_unused_functions` is not a real Elixir directive (and `{:nowarn_unused_function, [...]}` also doesn't silence them). Public `def`s are never warned about for being unused, so emitting helpers as public is the cleanest way to satisfy "zero warnings on output" without tree-shaking. Trade-off: a user could call `TranslatedCode.py_add(1, 2)` directly; acceptable since the module is generated for one-shot execution, not as a reusable library.
- **No `import Bitwise`** — Bitwise calls emitted fully-qualified (`Bitwise.bxor/2`, etc.). Verified empirically: `import Bitwise` with no usage emits an unused-import warning; Elixir has no per-module switch to suppress it. Fully-qualifying every call is unconditionally safe.
- Helper source-of-truth: `lib/pylixir/runtime_helpers.ex` is the *only* place helpers are hand-written, as `def`s. ExUnit calls them directly via `Pylixir.RuntimeHelpers.py_add(...)`. `lib/pylixir/helpers_codegen.ex` reads that file at **Pylixir's own compile time** via `@external_resource` + `File.read!`, slices the text between `# --- HELPERS START ---` / `# --- HELPERS END ---` sentinel comments, and bakes the slice into a `@helpers_source` string constant. Emission splices that constant into the output string. No drift, no file access at transpile time.
- Codegen emission policy for MVP: **emit ALL helpers in every output module**. Tree-shaking is a later optimization, not a ticket.
- Every node that's "out of scope" must raise `Pylixir.UnsupportedNodeError` with the `_type` string — never silently drop.

---

## Tickets

### Phase 0 — Project skeleton

**T01. `mix new` + repo layout**
- `mix new pylixir --module Pylixir`
- Add `priv/python/`, `test/fixtures/python/`, `test/fixtures/elixir/`, `lib/pylixir/nodes/` directories (with `.gitkeep`).
- Top-level `Pylixir` module with stub `to_source/1` returning `""`.
- `README.md` with 1-paragraph summary + link to RFC. Include a "Formatting" note: *Output is formatted with Elixir's default formatter at Pylixir's compile time. Running `mix format` on the output in a project with custom `.formatter.exs` settings (e.g., different `line_length`) may produce further changes — this is expected.*
- `.gitignore` (defaults + `/tmp/`).
- Acceptance: `mix test` runs (one trivial test); `mix compile` warns about nothing.

**T02. CI + tooling**
- `.github/workflows/ci.yml`: Elixir 1.19 / OTP 28 + Python 3.14.5 (`actions/setup-python@v5` with `python-version: '3.14.5'`). Run `mix deps.get`, `mix format --check-formatted`, `mix test`, `mix credo --strict`.
- Trap: Ubuntu 24.04 system `python3` is 3.12. Ensure the setup-python install is on `PATH` ahead of system Python, or invoke via `$pythonLocation/python3` — otherwise `T33` shells out to the wrong interpreter.
- Add `:credo` to deps (dev/test only). (Skip `:dialyxir` — opt-in later if useful.)
- `.formatter.exs` already created by `mix new`; verify.
- Acceptance: green CI on a no-op push; `python3 --version` step prints `3.14.5`.

**T03. Errors + Context struct + dispatch skeleton + scope-walk primitive**
- `lib/pylixir/errors.ex`: `Pylixir.UnsupportedNodeError` with fields `node_type: String.t()`, `hint: String.t() | nil`, `lineno: pos_integer() | nil`, `col_offset: non_neg_integer() | nil`. `message/1` callback formats as `"#{node_type} at line #{lineno}, col #{col_offset}: #{hint || "not supported"}"` when lineno present, falls back to `"#{node_type}: #{hint || "not supported"}"` otherwise.
- Hint table: `@hints %{"ClassDef" => "Python classes are not supported; use a module of functions plus a data map.", ...}` keyed by `_type`. ~30 entries to author over T03 + T31 (T03 lands the mechanism + 3–5 representative entries; T31 fills the rest as part of the coverage matrix).
- `lib/pylixir/context.ex`: struct per §10.2 (`scopes`, `while_counter`, `loop_nesting`, `known_functions`, `temp_counter`). `temp_counter` is the shared monotonic counter for single-evaluation temps generated in T12 (chained `Compare` middles), T13 (multi-target assign RHS), and T14 (`AugAssign` subscript value/slice).
- `lib/pylixir/converter.ex`: `convert/2` with a single catch-all clause that raises `UnsupportedNodeError`, pulling `Map.get(node, "lineno")` / `Map.get(node, "col_offset")` (may be `nil` for synthesized / root nodes), looking up `hint` from the table.
- `lib/pylixir/ast/walk.ex`: shared scope-aware AST-walk primitive `walk_scope(node, acc, fun) :: acc`. Pre-order; visits the boundary node itself but does NOT descend into its body for any of: `FunctionDef`, `AsyncFunctionDef`, `Lambda`, `ClassDef`, `ListComp`, `SetComp`, `DictComp`, `GeneratorExp`. Used by T16a (assigned-vars analysis), T19 (top-level function-name collection), and T20 (return-inside-loop detection). One primitive, one set of boundary tests; no near-duplicate walkers.
- Acceptance: unit test that `convert(%{"_type" => "ClassDef", "lineno" => 14, "col_offset" => 0}, ctx)` raises with the four fields populated and the formatted message matches the spec. Unit tests for `walk_scope`: confirms it visits `FunctionDef`/`Lambda`/`ClassDef`/comprehension nodes but does not descend into their bodies; confirms it walks normally through `If`/`For`/`While`/`Try` etc.

**T04. Formatter pipeline + `Pylixir.to_source/1` entry**
- Implement §10.11 exactly: `Macro.to_string |> Code.format_string! |> IO.iodata_to_binary`. Trap: don't drop the iodata step (§3.1).
- `to_source/1` calls `collect_function_names/1` (§10.3) and seeds `Context`.
- **Idempotency**: output is a fixed point under the same formatter. Unit-test asserts `Code.format_string!(output) |> IO.iodata_to_binary() == output` for the trivial round-trip. This guards against Pylixir emitting AST that the formatter doesn't fully normalize on the first pass — caught early, not deferred to T32.
- Acceptance: round-trip `quote do: 1 + 2` through the pipeline; assert binary string output **and** that re-formatting it is a no-op.

**T04b. Test infrastructure for compile-and-eval (`Pylixir.TranspileHelpers`)**
- New file `test/support/transpile_helpers.ex`. Wire `elixirc_paths/1` in `mix.exs` so `test/support/` is compiled only in `:test` env.
- Public test API:
  - `transpile_and_run(ast) :: {output_string, run_return_value, captured_stdout, diagnostics}`
  - `transpile_and_capture(ast) :: captured_stdout` (thin wrapper that asserts `diagnostics == []`)
- Implementation:
  - Call `Pylixir.to_source(ast)`.
  - `Code.string_to_quoted!/1` the output. AST-walk: rewrite the `defmodule TranslatedCode do ... end` alias to a unique module atom (`:"TranslatedCode_#{:erlang.unique_integer([:positive])}"`); detach the trailing `TranslatedCode.py_main()` call and re-attach as an explicit `<UniqueModule>.py_main()` call on the unique module post-compile.
  - **Wrap `Code.compile_quoted/1` in `Code.with_diagnostics/1`** (Elixir 1.15+; we're on 1.19.5). This returns `{compile_result, diagnostics}` where `diagnostics` is a structured list of `%{severity, message, position, ...}` maps. Zero noise from unrelated stderr output, no process-global state. The helper returns this list as the 4th tuple element so tests can assert on it.
  - Wrap the unique `Module.run()` invocation in `ExUnit.CaptureIO.capture_io/1`.
  - Returns the four-tuple above.
- `transpile_and_capture/1` (the common test entry point) **asserts `diagnostics == []` internally** — any compile warning fails the test by default. Callers wanting to inspect diagnostics use the full `transpile_and_run/1`.
- Add `Code.compiler_options(ignore_module_conflict: true)` to `test_helper.exs` as belt-and-braces (the unique name should prevent collisions; this just keeps a helper bug from nuking the whole suite).
- Tests using the helper may run `async: true`. Document this in the helper's `@moduledoc`.
- **Trap to flag in helper docs**: `Code.compile_quoted` defines modules globally; each unique name accumulates BEAM memory for the suite's lifetime. Bounded (~few MB) and acceptable for MVP.
- Acceptance: helper test that runs `transpile_and_run` on a minimal `Module` AST (output from T05 once landed, or a hand-rolled `{:defmodule, ...}` quoted AST stand-in if T04b lands before T05) returns the expected four-tuple shape; diagnostics list is empty for clean input; **diagnostics list is non-empty for a deliberately-warning-emitting test input** (e.g., AST with an unused variable) — guards against a helper bug that swallows diagnostics silently.

**T05. Module wrapper + helpers injection**
- `Module` node → `defmodule TranslatedCode do <helpers...>; <module_attrs...>; <function_defs...>; def py_main, do: <runtime_statements> end` + trailing `TranslatedCode.py_main()` (§3.4). **Wrapper function name uses the `py_` prefix** so it cannot collide with any user Python identifier (T07's `^py_` inverse-collision guard rejects user names starting with `py_`). Without this, a user Python `def run():` would produce two `run/0` clauses in the generated module and fail to compile.
- **Module-body partitioning** (critical for top-level constants accessed from functions):
  1. `function_defs`: `FunctionDef` nodes → module-level `defp`s (T19).
  2. `module_attrs`: `Assign(targets=[Name(name)], value=literal)` where `literal` is `Constant`/`List`/`Tuple`/`Dict` of recursively-literal values → module attributes `@var_<name> <value>` (Elixir compile-time constants).
  3. `runtime_statements`: everything else in `Module.body` → inside `def py_main`'s body, in original order.
- Without this partitioning, the common Python pattern `PI = 3.14; def area(r): return PI * r * r` fails to compile because `defp area` can't see `py_main`'s locals.
- **`Context.module_attrs`** tracks which Python names became `@var_<name>` attributes. T07's `Name` converter checks this set: if the name is a module attribute, emit `@var_<name>` instead of `var_<name>`.
- **Reassignment of a module-attr name** anywhere in the program (including in `py_main`'s runtime statements or inside functions) raises `UnsupportedNodeError` with hint "cannot reassign module-level literal `<name>`; convert to a parameter or compute at runtime". Module attributes are compile-time constants — mutating them silently would diverge from Python's late-binding semantics.
- **Translation-time free-name check** in T19: when emitting a function body, walk it for `Name`s. Any name that isn't (args ∪ local scope ∪ builtins ∪ known_functions ∪ module_attrs) raises `UnsupportedNodeError` with hint "module-level variable `<name>` is non-literal and not accessible inside functions; make it a parameter or convert to a constant".
- **No `import Bitwise`** — Bitwise operations (T11) emit fully-qualified `Bitwise.bxor/bnot/bsl/bsr/bor/band/2` calls. Verified empirically: `import Bitwise` in a module without bitwise usage emits `warning: unused import Bitwise` and Elixir has no per-module switch to suppress that. Fully-qualifying every call avoids the warning unconditionally — important because most Python programs don't use bitwise ops, and the warning would fail T04b's `diagnostics == []` assertion.
- `lib/pylixir/runtime_helpers.ex`: hand-write every helper from §9 **as public `def`s** (verified empirically: `@compile :nowarn_unused_functions` is not a real Elixir directive; public `def`s are simply never warned as unused). Wrap the helper block in `# --- HELPERS START ---` / `# --- HELPERS END ---` sentinel comments. This is the **single source of truth**.
- `lib/pylixir/helpers_codegen.ex`: `@external_resource` + `File.read!` of runtime_helpers.ex at Pylixir's compile time; slice between sentinels; expose as `@helpers_source` string constant for emission.
- Add ExUnit tests that exercise each helper directly (§11.3 cases for `truthy?`, `py_add`, `py_str`, `py_round`, `py_hex`, `py_str_count`, boolean arithmetic, MapSet truthiness).
- Add unit test that compiles the sliced helper text inside a throwaway `defmodule` via `Code.compile_string/1` — catches helper-source breakage at unit-test time, not just end-to-end.
- Use `Pylixir.TranspileHelpers` (T04b) for the compile-and-eval acceptance test.
- Acceptance: `to_source/1` on empty `Module` produces compiling Elixir source (run via `transpile_and_run` from the test) **with zero compiler warnings** (helper asserts no warnings during `Code.compile_quoted`).

### Phase 1 — Literals + variables

**T06. `Constant` node**
- int / float / str / bool / nil → self-representing Elixir literals (post-JSON-decode bool/None become Elixir `true`/`false`/`nil`).
- **Unsupported literals via tagged shape** (coordinated with T33's `serialize.py`): when `value` is a map with key `"_unsupported_literal"`, raise `UnsupportedNodeError` with `node_type: "Constant"` and hint referencing the literal kind (e.g., `"Python complex literal 3+4j is not supported"`). Tagged shapes emitted by `serialize.py`'s custom JSON encoder:
  - `complex` → `{"_unsupported_literal": "complex", "repr": "3+4j"}`
  - `bytes` → `{"_unsupported_literal": "bytes", "repr": "b'hello'"}`
  - `Ellipsis` → `{"_unsupported_literal": "ellipsis"}`
- Acceptance: parametrised tests for each Python literal type; **explicit tests for each tagged unsupported shape** asserting `UnsupportedNodeError` with the literal kind named in the hint and `lineno`/`col_offset` populated.

**T07. `Name` node + `Pylixir.Naming` collision policy**
- `Name` → `{:name_atom, [], nil}` 3-tuple.
- **Module-attribute reference**: if `id` is in `Context.module_attrs` (populated by T05's partitioning), emit `@var_<id>` (Elixir module-attribute syntax) rather than `var_<id>`. This is what makes top-level literal constants like `PI = 3.14` accessible from inside functions.
- **Special-case `__name__`**: emit the literal string `"__main__"` instead of a variable reference. Rationale: Pylixir's generated `TranslatedCode.py_main()` is the entry point — the analogue of Python running a file as a script — so the idiom `if __name__ == "__main__":` should resolve true. Without this, the generated code references an undefined Elixir variable. Other Python dunder names (`__file__`, `__doc__`) are not in scope for MVP — they would raise via the standard `Name` path falling through.
- **Distinct prefix namespaces** to avoid helper/user collisions:
  - Helpers (defined by Pylixir): `py_<name>` (e.g. `py_add`, `py_str`).
  - Rewritten user identifiers: `var_<name>` (e.g. `var_length`, `var_if`).
- `Pylixir.Naming` enumerates the **full collision set** at compile time (not at T07 implementation time — fully decided now):
  - **Category 1 — hard-reserved keywords** (parser rejects as var name): `true`, `false`, `nil`, `when`, `and`, `or`, `not`, `in`, `fn`, `do`, `end`, `catch`, `rescue`, `after`, `else`. Mandatory rewrite.
  - **Category 2 — special-form atoms** (valid as vars but shadow the form): `if`, `unless`, `case`, `cond`, `for`, `receive`, `try`, `with`, `quote`, `unquote`, `super`, `__MODULE__`, `__DIR__`, `__ENV__`. Mandatory rewrite.
  - **Category 3 — Kernel auto-imports**: derived programmatically via `Kernel.__info__(:functions) ++ Kernel.__info__(:macros)` baked into a `@reserved_names` MapSet at Pylixir's own compile time. Auto-tracks future `Kernel` additions.
- **Inverse-collision protection**: any Python identifier matching `^var_` or `^py_` raises `UnsupportedNodeError` (with a clear message). Prevents a Python `var_length` colliding with the rewritten `length` → `var_length`, and a Python `py_add` colliding with the helper. Small Python surface loss, zero ambiguity.
- Acceptance: tests for plain ids; tests for ids from each of the three categories; tests confirming Python `var_foo` and `py_foo` both raise.

**T08. `List`, `Tuple`, `Dict` literals**
- `List` → Elixir list AST.
- `Tuple` → 2-tuple literal for n=2, `{:{}, [], elts}` for n≠2 (§5.2).
- `Dict` → `%{}` map AST; reject any entry where `keys[i] == nil` (dict-unpack `{**d}`) with `UnsupportedNodeError`.
- **Reject `Starred` inside `List.elts`/`Tuple.elts`** with `UnsupportedNodeError` and hint "Star-unpack inside list/tuple literal `[*xs, ...]` is not supported; use `xs + [...]` instead." Equivalent rewrite is supported via `py_add` list concat. Added to T31's coverage matrix.
- Acceptance: nested literals; empty collections; **explicit rejection test for `[*xs, 3]` with a non-trivial hint**.

### Phase 2 — Operators

**T09. `UnaryOp`**
- `UAdd` (no-op), `USub` (`-x`), `Invert` (`~x` → `Bitwise.bnot/1`), `Not` (`!truthy?(x)` — depends on helper from T05; ok since helpers are always emitted).
- Acceptance: each unary op tested.

**T10. `BinOp` arithmetic (Add, Sub, Mult, Div, Pow)**
- `Add` → `py_add/2`; `Mult` → `py_mult/2`; `Pow` → `py_pow/2`; `Sub` → `-`; `Div` → `/`.
- Edge cases (§6.8 string concat, §6.9 list/string repeat, §6.10 float-vs-int pow, §6.11 boolean arithmetic).
- Acceptance: integration test that compiles + evals output for each case; matches Python results.

**T11. `BinOp` floor-div, mod, bitwise**
- `FloorDiv` → `py_floor_div/2` helper (wraps `Integer.floor_div/2`, raises with clear hint for non-integer operands; same dispatch pattern as `py_add`).
- `Mod` → `py_mod/2` helper. Python's `%` is **dual-meaning**: numeric modulo and string %-formatting. The helper dispatches at runtime: integers → `Integer.mod/2`; binary left → raise with hint "Python %-string formatting (`'%s' % name`) is not supported; use string concatenation"; everything else → raise FunctionClauseError-style with a hint. Without this helper, `"hi %s" % name` translates to `Integer.mod("hi %s", name)` and the user sees an opaque `FunctionClauseError` with no Python-level context.
- `LShift` → `Bitwise.bsl/2`, `RShift` → `Bitwise.bsr/2`, `BitOr` → `Bitwise.bor/2`, `BitAnd` → `Bitwise.band/2`, `BitXor` → `Bitwise.bxor/2` (§6.22). **All fully-qualified** since T05 doesn't `import Bitwise` (avoiding unused-import warning on programs without bitwise ops).
- Reject `MatMult`.
- New helpers (`py_floor_div`, `py_mod`) live in `runtime_helpers.ex` alongside the others.
- Acceptance: tests for negative-operand floor-div and mod; **a Python program with zero bitwise ops compiles with no warnings** (regression guard against the import being added back); **`"%s" % name` at runtime raises with `py_mod`'s hint message, not `FunctionClauseError`**.

**T12. `BoolOp` + `Compare` (with chaining + side-effect safety)**
- `BoolOp` (`And`/`Or`) → `&&`/`||` over the `values` list (§5.3, §6.3 caveat).
- `Compare` with **one** comparator (`a < b`) → plain binary op, no temp.
- `Compare` with **two or more** comparators (`a < b < c`, …) → fold into `&&`-chain, **binding non-trivial middle operands to temps** to preserve Python's single-evaluation semantics. Without this, `f() < x() < g()` evaluates `x()` twice and silently diverges from Python.
  - Predicate `Pylixir.AST.trivial?/1` returns true for `Constant`, `Name`, and `Attribute` whose `value` is recursively trivial. False otherwise.
  - For each middle operand at positions 1..n-1 in the chain: if non-trivial, bind `py_tmp_<n> = <operand>` in a `__block__` and reference `py_tmp_<n>` in both adjacent comparisons.
  - Temp names use the `py_` prefix so they cannot collide with user Python identifiers (T07's `^py_` inverse-collision guard rejects user names starting with `py_`). Counter lives in `Context.temp_counter` (T03), shared with T13 and T14 — single monotonic counter, no name reuse anywhere in the same function.
- `In`/`NotIn` → `py_in/2` (and `!` for NotIn). `Is`/`IsNot` → `==`/`!=` (§10.10).
- Optimization: `if`/`while` conditions whose root is `Compare` skip `truthy?` wrap (later — T15).
- Acceptance: tests including `1 < x < 10` (trivial middle, no temp), `1 < compute() < 10` (non-trivial middle, assert temp emitted and side effect runs exactly once), `x in [...]`, `x is None`, plus a stress test for nested chained compares to confirm counter uniqueness.

### Phase 3 — Assignment

**T13. `Assign` (simple, multi-target, tuple unpack)**
- Single `Name` target → `target = value`.
- **Multiple targets (`a = b = compute()`)** — Python evaluates the RHS exactly once and assigns to each target. Naive `a = compute(); b = compute()` would double-evaluate side effects (same divergence pattern as T12 chained `Compare`). Fix:
  - If RHS satisfies `Pylixir.AST.trivial?/1` (T12): inline as `__block__([a = rhs, b = rhs])`.
  - Otherwise: bind to a temp first — `__block__([py_tmp_n = rhs, a = py_tmp_n, b = py_tmp_n])`. Counter via `Context.temp_counter` (shared with T12 and T14). Temps use `py_` prefix → collision-free with user identifiers.
- `Tuple` target → `{a, b} = {b, a}` style (§10.9). Reject `Starred` in target.
- Update `Context.scopes` to record bound names.
- Acceptance: tests for each shape, plus tuple swap; **plus a `compute()`-side-effecting RHS in multi-target assign asserting single evaluation**.

**T14. `AugAssign` (all ops + subscript targets)**
- Per §7.2 table. Subscript target → `py_setitem/py_getitem` rewrite (§7.3).
- **Single-evaluation guarantee for subscript targets.** Naive `d = py_setitem(d, k, py_getitem(d, k) + 1)` evaluates `d` and `k` twice. For `get_dict()[get_key()] += 1`, both side effects would fire twice — silent divergence from Python.
  - Use `Pylixir.AST.trivial?/1` (T12) on each of `value` (the collection) and `slice` (the key). If trivial: inline. If non-trivial: bind `py_tmp_n = expr` first, then reference the temp on both reads and the write.
  - Counter via `Context.temp_counter` (shared with T12 and T13).
- Acceptance: `x += 1`, `d[k] += 1`, `lst[i] *= 2`, all bitwise/arith ops; **plus `get_dict()[get_key()] += 1` asserting both side effects fire exactly once**.

### Phase 4 — Control flow

**T15. `If`/`Pass`/`IfExp`**
- **Three `If` shapes**, dispatched on `orelse`:
  - `orelse == []` → Elixir `if cond, do: body`.
  - `orelse` is one or more non-`If` statements → Elixir `if cond, do: body, else: else_body`.
  - `orelse == [%{"_type" => "If", ...}]` (elif chain) → flatten via `cond do ...; true -> nil end`. The `true -> nil` fallthrough is **always appended** unless the chain has a terminal Python `else`. Without it, `cond` raises `CondClauseError` at runtime when no branch matches; Python silently does nothing.
- `Pass` → `:ok` literal (no-op).
- `IfExp` ternary → `if test, do: body, else: orelse` (note argument order §AST 4.4).
- `truthy?` wrap precision: skip the wrap **only when the condition node satisfies `Pylixir.AST.bool_returning?/1`**, which returns `true` exclusively for `_type == "Compare"`. Defined alongside `trivial?/1` (T12) and `walk_scope/3` (T03) in `Pylixir.AST` so future tightening (e.g., `BoolOp` over two `Compare`s) localizes to one predicate. Every other condition shape — `Name`, `BoolOp`, `Call`, `Constant` of any value — gets wrapped.
- Acceptance: one test per `If` shape; ternary test; empty-body test; **test that elif-without-else evaluates to `nil` when no branch matches (doesn't raise)**; **test that `if x and y: ...` emits `if truthy?(x && y), do: ...`, not `if x && y, do: ...`**.

**T16a. For-loop scope analyzer (pure function, no codegen)**
- New module `lib/pylixir/scope.ex` (or inside `nodes/statements.ex`): pure function `analyze_for_body/1` taking a `For.body` list, returning `%{assigned_vars: [...], loop_var_leaks: bool}`.
- Implemented on top of `Pylixir.AST.walk_scope/3` (T03) — boundary handling (FunctionDef/Lambda/ClassDef/comprehensions) is inherited from the shared primitive, not re-derived here.
- Over-thread policy: collect every name that appears as LHS of `Assign`/`AugAssign`, as a loop var of an inner `For`, or as the **root `Name`** of a subscript/attribute target (since `py_setitem` rebinds the root collection). Union assigned-vars from nested `For`/`While`/`If`/`Try` arms upward.
- Loop var itself is always included in `assigned_vars` (Python loop var leaks per function-scope semantics).
- Edge cases the analyzer must handle: conditional assignment (var may be unbound — init to `nil`), reassigning the loop var, augmented assignment, nested loops, subscript/attribute assignment.
- Acceptance: ~12 hand-written AST snippets unit-tested against expected `assigned_vars` sets. Includes: a nested `FunctionDef` inside the loop body whose assignments do NOT leak into the outer assigned-vars set. No codegen involved.

**T16b. For-loop codegen (no break/continue)**
- Consumes `T16a` analyzer output. **Branch on `assigned_vars` cardinality**:
  - **0** (pure side-effect loop, e.g., `for i in xs: print(i)`) → emit `Enum.each(xs, fn x -> body end)`. Cleaner output; returns `:ok`.
  - **1** → `Enum.reduce/3` with a single-value accumulator (not a tuple — `acc`, not `{acc}` — Enum.reduce tuple-unpack syntax trap).
  - **2+** → `Enum.reduce/3` with tuple accumulator threading every var.
- Read-only externals stay captured by the closure.
- Initial accumulator: for each var in `assigned_vars`, use the var's outer binding if present in `Context.scopes`, else `nil`. Post-loop, rebind every var from the reduce result.
- `For.orelse` non-empty → raise.
- Only the `For` node *without* break/continue/return in body (those land in T17 / T20).
- Acceptance: pure side-effect loop (no assigned_vars; uses Enum.each); single assigned var (sum-of-list); multi-var loops; conditional-assign-in-body; nested for; subscript-mutation-in-body.

**T17. For-loop with `break` / `continue`**
- Reuses T16a analyzer. `continue` → return accumulator unchanged (terminate fn arrow). `break` → `throw({:pylixir_break, acc})` wrapped in `try do ... catch :throw, {:pylixir_break, acc} -> acc end`.
- **Exact-tuple `catch` pattern required** — a generic `catch x -> x` would swallow T20's `{:pylixir_return, v}` and silently turn a `return` inside the loop into a normal loop result. Only the exact `{:pylixir_break, _}` shape is caught; anything else propagates upward.
- Namespacing rationale: `:pylixir_break` (rather than `:break`) avoids accidental catches of unrelated user throws if Pylixir ever interoperates with hand-written Elixir.
- Acceptance: loop that breaks mid-way; loop with continue filter; **`break-and-return-in-same-loop`** test — the function should return via T20's catch (the inner loop catch lets the `:pylixir_return` throw through).

**T18. `While` loop (recursive helper)**
- §10.5 template. Each `While` becomes `defp while_<n>(...)` (counter in Context). Returns final state tuple. Caller pattern-matches `{vars...} = while_n(...)`.
- **`While.orelse` non-empty → raise** (same convention as `For.orelse` in T16b).
- Body scope analysis: reuse T16a analyzer over the `While.body` (same semantics).
- `continue` → `throw(:pylixir_continue)`; each iteration's body is wrapped in `try do ... catch :throw, :pylixir_continue -> :ok end` so a thrown continue short-circuits to the next recursive call with current state.
- `break` → `throw({:pylixir_break, state})` caught by `try do ... catch :throw, {:pylixir_break, state} -> state end` around the recursive entry.
- **Exact-pattern `catch` clauses, same rationale as T17.** A `return` inside a while body propagates through both the continue and break catches to T20's function-level catch.
- Acceptance: loop convergence; break; continue; **`continue-and-return-in-same-while-loop`** test confirming `return` propagates correctly.

### Phase 5 — Functions

**T19. `FunctionDef` + `arguments` + `arg` + defaults**
- Pre-pass (`collect_function_names/1`, hooked in T04) walks **only the top-level `Module.body`** via `Pylixir.AST.walk_scope/3` (T03). Nested `FunctionDef`/`Lambda` bodies are not descended into — those are T21's anonymous-fn territory. Trap: if the pre-pass descended into nested defs, T28's `Call` router would route `inner(5)` as a module call when T21 has bound `inner` as an anonymous `fn`, and Elixir's `inner.(5)` syntax difference would make the generated code fail to compile.
- Emit `defp name(args), do: body` (use `do:` short-form when body is one expression).
- Defaults via `{:\\, [], [param_ast, default_ast]}` (§5.2). Defaults apply to LAST n args.
- Reject `vararg`, `kwarg`, `kwonlyargs`, non-empty `decorator_list`, `posonlyargs`.
- **`type_params` silently ignored** (PEP 695 generic syntax, `def foo[T](x: T):`). No runtime effect in Python — type params are static-only hints. Use `Map.get(node, "type_params", [])` per RFC §184. Same treatment as `from __future__ import annotations` — accept and drop. **Distinct** from `decorator_list` which is rejected because decorators have real runtime semantic effect.
- New scope frame in Context; pop on exit.
- Acceptance: function with defaults, recursive function, forward reference, **plus an explicit test that a nested `def` inside an outer `def` does NOT appear in `Context.known_functions`** (regression guard against pre-pass descending).

**T20. `Return` (conservative tail-position rule)**
- **Critical correctness rule**: a Return outside a loop is *still* an early exit and must throw/catch unless it's the function's literal final statement at top level. The plan's earlier "Return inside any loop body" rule was insufficient — `def foo(): if x: return 1; print("y"); return 2` would emit code that prints "y" even when `x` is true (Elixir's `if` returns a value but doesn't exit the function).
- Wrap rule (Option B — conservative, simple, always correct):
  1. Walk `FunctionDef.body` via `Pylixir.AST.walk_scope/3` (T03). Walk stops at nested `FunctionDef`/`Lambda`/`ClassDef`/comprehension boundaries — nested function returns belong to the nested function.
  2. Count Return nodes in the function's own scope.
  3. **Wrap the entire function body in `try do ... catch :throw, {:pylixir_return, v} -> v end` iff** the function has either:
     - **2+ Returns**, OR
     - **1 Return that is not the function's top-level last statement** (e.g., it's nested inside an `If`, `For`, `While`, or `cond` arm, regardless of whether *that* construct is tail-position).
  4. Otherwise (zero Returns; or one Return that IS the function's final top-level statement): no wrap.
- **Throw vs value emission**:
  - In a wrapped function: every Return emits `throw({:pylixir_return, value})`.
  - In an unwrapped function (the single tail Return case): emit just the value naturally.
  - Bare `return` → `throw({:pylixir_return, nil})` (wrapped) or `nil` (unwrapped tail).
- Namespaced tag matches T17/T18; nested loop break/continue catches use exact-tuple patterns and let `{:pylixir_return, _}` propagate.
- Acceptance covering each rule branch:
  - `def foo(): return 1` — no wrap (single tail).
  - `def foo(): if x: return 1; print("y"); return 2` — wrap; assert "y" doesn't print when `x` is true.
  - `def foo(): for i in xs: return i` — wrap (Return inside loop, hence not function's top-level last statement).
  - `def foo(): if x: return 1` (no else, no following code) — wrap (Return is *inside* the If, not at top-level).
  - `def foo(): if x: pass else: pass; return 1` — no wrap (single tail Return at function top level).
  - **`find_first` example from §10.6**.
  - **Regression guard**: a function whose only `return` is inside a nested `def` does NOT get the outer body wrapped (walk_scope boundary).

**T21. `Lambda` + nested `FunctionDef` (with explicit self-passing spec)**
- `Lambda` → `fn args -> body end`. Plain case; no self-passing needed unless self-reference is detected (see below).
- Nested `def` inside another `def` → bind as `<name> = fn args -> body end` (§10.8). Plain case if the body has no self-reference.
- **Self-reference detection**: walk the nested `FunctionDef.body` via `Pylixir.AST.walk_scope/3` (T03) looking for `Call(func=Name(<inner_name>))`. If found, mark the nested def as recursive.
- **Recursive transform** (when self-reference is detected):
  - Append a synthetic `self` parameter to the emitted `fn`'s param list.
  - Rewrite every `<inner_name>(args)` call within the body to `self.(args, self)`.
  - Emit the binding as `<inner_name> = fn args..., self -> rewritten_body end`.
  - At every *outer* call site of the inner — i.e., where the enclosing function invokes `<inner_name>(args)` — rewrite to `<inner_name>.(args, <inner_name>)`.
- **Lambda self-reference**: same rule applies to `Lambda` when its parent is `Assign(targets=[Name(name)], value=Lambda(...))` and the lambda body references `name`. Python uses late binding here, but the self-passing transform makes the Elixir emission semantically equivalent without late-binding hacks.
- **Mutual recursion between nested defs is unsupported**: a nested def whose body references *another* nested-def name (not its own) raises `UnsupportedNodeError` with the hint "mutual recursion between nested defs is unsupported; lift to module-level functions". Detection: when finalizing a nested def, scan its body for `Call(func=Name(id))` where `id` is another sibling nested-def name in the same enclosing scope.
- Acceptance:
  - Plain nested `def` (no recursion) — emitted as plain `fn`.
  - Recursive inner (`fact` example) — self-passing transform; `fact.(5, fact)` from outer; result correct.
  - Lambda assigned-to-name with self-reference (`f = lambda n: ... f(n-1) ...`) — self-passing transform applied.
  - Mutual recursion (`def a(): def b(): ...; def c(): b()...`) — raises `UnsupportedNodeError`.

### Phase 6 — Subscripts, slices, comprehensions

**T22. `Subscript` (index access) + `py_in` (collection membership)**
- Non-slice subscript → `py_getitem/2`. Dict key with `Map.fetch!` semantics (§6.6).
- Acceptance: list index, dict key (raises on missing), tuple index, negative index.

**T23. `Slice`**
- Implement full §6.18 table. `Slice.step` handled separately for negative-step ranges (§6.17 rules also apply analogously).
- Constant-step optimisation; variable-step falls back to runtime branch on sign.
- String slicing uses `String.slice/2`, `String.reverse/1`.
- Acceptance: every row in §6.18 verified by compile+eval against Python output.

**T24. `ListComp`**
- `[expr for x in iter if cond]` → `iter |> Enum.filter(fn x -> truthy?(cond) end) |> Enum.map(fn x -> expr end)`.
- Multiple generators → nested via `Enum.flat_map`.
- Multiple `ifs` → AND them inside a single filter.
- Acceptance: filtered comprehension, nested generators, no-filter case.

**T24b. `SetComp` / `DictComp` / `GeneratorExp`** *(deviation from RFC §4.4 — RFC must be updated; see below)*
- Shares ~90% of T24's pipeline construction. Extract the filter+map composition into a helper that all four comprehension nodes call.
- `SetComp` → wrap T24's list pipeline in `MapSet.new/1`.
- `DictComp` → `Map.new(filtered_iter, fn x -> {k_expr, v_expr} end)`.
- `GeneratorExp` → emit eagerly as a list (same code path as `ListComp`). Eager-vs-lazy divergence: Elixir has no direct lazy-sequence equivalent, and lazy emulation via `Stream` interacts poorly with `truthy?`-wrapped filters in MVP. Documented in the updated RFC §4.4.
- **RFC update required as part of this ticket**: remove `GeneratorExp`, `SetComp`, `DictComp` from RFC line 289's unsupported list; add a paragraph to RFC §4.4 documenting eager-vs-lazy behavior of `GeneratorExp`.
- Acceptance: each form tested with filter + nested generators; verify `sum(i*i for i in [1,2,3,4])` from the end-to-end verification example actually works; the RFC diff is part of the PR.

### Phase 7 — Builtins + methods

**T25a. Builtins: size + iteration shape primitives**
- `len` → `py_len`. `range` (all three arities incl. negative step §6.17). `sorted`, `reversed`, `enumerate` (note `{x, i}` swap §6.5), `zip` (2-arg + n-arg).
- **Keyword-arg support (whitelist; everything else rejects)**: `sorted(xs, key=fn, reverse=bool)` (extremely common); `enumerate(xs, start=n)`. Each handler reads `Call.keywords` and routes the named ones; any unrecognized keyword raises `UnsupportedNodeError` with a hint naming the keyword.
- Routing: `Call.func` is `Name` and id is in this table → emit mapped form. **The routing table itself lives in a shared module** (`Pylixir.Builtins.Registry` or similar) consumed by T25a/T25b/T26/T27 and by T28's router — so T28 doesn't reinvent the lookup.
- Acceptance: each builtin tested via end-to-end compile+eval; `sorted(xs, key=lambda x: x[0])`, `sorted(xs, reverse=True)`, `enumerate(xs, start=1)`; **unrecognized keyword like `sorted(xs, made_up=1)` raises** with the keyword name in the message.

**T25b. Builtins: aggregation + functional**
- `sum`, `min`/`max` (1-iter vs n-args), `abs` → `py_abs`, `map`, `filter`.
- **`min`/`max` keyword arg `default`**: `min(xs, default=0)` → `Enum.min(xs, fn -> 0 end)` (Elixir's `Enum.min/2` accepts a fallback function for the empty case). Same for `max`. Other keywords (`key=`) **not** supported in MVP — raise with hint.
- Adds entries to the shared `Pylixir.Builtins.Registry` from T25a.
- Acceptance: each builtin tested via end-to-end compile+eval; `min([], default=0)` returns `0` (does not raise at runtime, does not raise at translation); `min(xs, key=fn)` raises `UnsupportedNodeError` with `key` in the hint.

**T26. Builtins: conversions + type checks**
- `int`/`float`/`str`/`bool`/`list`/`tuple`/`set`/`dict` per §8 table.
- **`float()` carve-out (RFC §564)**: when the argument is a `Constant` with string value `"inf"`, `"-inf"`, `"nan"` (any case via lower-casing the literal), raise `UnsupportedNodeError` at translation time — not runtime — with hint "Python float('inf')/float('nan') has no `Float.parse/1` equivalent; not supported". For non-literal `Constant` argument (e.g., `float(user_input)`), emit `py_float/1` which calls `Float.parse/1` and raises at runtime if it returns `:error`. The string carve-out is detected only for literal AST `Constant`s; runtime user input flows through `py_float`.
- `type(x) == T` and `isinstance(x, T)` per §8 table, incl. tuple-of-types form and the `isinstance(x, int)` ⇒ `is_integer(x) || is_boolean(x)` fix (§6.13).
- Acceptance: each conversion + each type-check predicate; `isinstance(True, int) == true`; **`float("inf")` literal raises at translation time** (not runtime); **`float(user_input)` compiles** and uses `py_float/1` at runtime.

**T27. Builtins: IO + numeric formatting + rounding**
- `print()` no-args, single, multi (§8 — `Enum.join` of `py_str`'d args).
- **`print` keyword args**: `sep=` and `end=` accepted (both are common). `file=` raises with hint ("redirecting stdout requires Elixir's `IO.puts(device, ...)` — not currently supported"). `flush=` ignored (no-op in MVP, since Elixir's `IO.puts` is line-buffered by default and the divergence is minor). Any other keyword raises.
- `input(prompt)` → `py_input`.
- `chr`/`ord`/`hex`/`oct`/`bin` per §8 (note `hex(-255)` → `"-0xff"` §6.7-adjacent).
- `round(x)` and `round(x, n)` → `py_round` (banker's §6.14).
- `divmod`, `any`, `all` (latter two need `&truthy?/1` — §16 #23).
- `math.*` table: detect `Attribute` with `value.id == "math"` (§10.1). Module-level `import math` silently produces no code; all other imports raise.
- `math.inf`/`math.nan` raise (§6.19).
- Acceptance: each builtin; print of bool/None/list/tuple/dict matches Python str()/repr(); **`print("a", "b", sep="-", end="!")` produces `"a-b!"`**; **`print("x", file=sys.stderr)` raises**.

**T28. `Attribute` dispatch + dict/list/set/string method routing**
- **Dict methods covered in this ticket**: `items`, `keys`, `values`, `get(k)` (1-arg, returns `Map.get(map, k)` — yields `nil` for missing), **`get(k, default)`** (2-arg, returns `Map.get(map, k, default)` — yields `default` for missing). The 2-arg form is common Python; no extra mechanism needed since Elixir's `Map.get/3` accepts a default natively.
- Centralised `Call` handler with **strict precedence**:
  1. **Local-scope shadowing** — if `Call.func` is `Name(id)` and `id` is bound in `Context.scopes` (any frame from innermost outward, before checking known_functions), emit `<rewritten_name>.(args)` (Elixir anonymous-function-call syntax). This handles Python's local-shadows-module pattern: `def a(): b = lambda: ...; return b()` must call the local lambda, not module-level `b`.
  2. Otherwise, branch by `Call.func` shape:
     - **`Name(id)` known cases**: math builtin → regular builtin → known module-level function. None matched and `id` isn't locally bound → emit as-is `<id>(args)` (matches Python's NameError behavior at runtime; user sees a recognizable error).
     - **`Attribute(value, attr)` known cases**: mutation method (§7.4) iff parent is `Expr` (statement context) → expression-level method (§7.5) → math-module call (when `value` is `Name("math")`). **None matched → `UnsupportedNodeError`** with hint `"method .<attr>() is not supported"`. Critical: do NOT emit as-is — `name.format("x")` emitted literally would become an Elixir remote-call (`name` interpreted as module), producing a confusing `BadFunctionError` far from the source. An explicit `UnsupportedNodeError` at translation time is much better feedback.
     - **Other `Call.func` shapes** (e.g., `Call(func=Lambda(...))` — calling a lambda inline): emit as Elixir `(<lambda>).(args)`.
- **Scope storage convention**: `Context.scopes` stores **Python names** (the original identifier strings from the AST). T07's `var_<name>` / collision-rewrite is applied at codegen time only — never in scope tracking. This avoids double-rewrite bugs in lookup.
- This ticket implements just the *router* + dict methods (`items`, `keys`, `values`, `get`) since they're simplest.
- Acceptance: routing tests covering each branch; dict method evaluations; **explicit local-shadows-module test**: top-level `def b(): return 1` plus inner `def a(): b = lambda: 2; return b()` — `a()` returns `2`, not `1`; **explicit unsupported-attribute test**: `"hello".format("x")` raises `UnsupportedNodeError` with `"method .format()"` in the message.

**T29a. String methods: case, whitespace, prefix/suffix, join**
- `lower`, `upper`, `strip`, `lstrip`, `rstrip`, `startswith`, `endswith`.
- `sep.join(items)` arg-swap (§10.1).
- Reject multi-char `strip(chars)` (§6.24).
- Acceptance: per-method tests; rejection test for multi-char strip.

**T29b. String methods: search, split, replace, classification**
- `split` incl. `maxsplit` form, `replace` incl. `count=1` form §6.23, `find`, `count`, `index`, `zfill`, `isdigit`, `isalpha`, `isalnum`.
- Reject `count > 1` to `replace` (§6.23). `split("")` documented divergence (§6.20) — emit with comment header in output noting Python-vs-Elixir behavior, or raise; pick **raise** to keep generated output free of divergence comments.
- Helpers `py_str_find`, `py_str_count` already in T05 — extend if needed.
- Acceptance: per-method tests; rejection tests for `replace` count > 1 and `split("")`.

**T30. List/dict/set mutation methods + expression-context pop**
- Statement-context (`Expr`-wrapped) mutations rewrite to `x = …` per §7.4 table.
- **`pop()` and `pop(i)` in assignment context** (§7.4 note): emit `{removed, x} = List.pop_at(x, i_or_-1)` then split if a parallel-assign target is needed. No-arg `pop()` uses index `-1` (last); explicit `pop(i)` uses the given index. Two-statement `__block__` per §7.4.
- **`list.sort(key=fn, reverse=bool)` keyword args** accepted (same allowed set as `sorted` in T25a). Other keywords raise. `list.sort()` no-args already covered.
- `list.remove` documented (returns unchanged when not found).
- Acceptance: append, sort variants (including `xs.sort(key=...)` and `xs.sort(reverse=True)`), pop in both contexts (no-arg AND `pop(i)`), dict.update, MapSet.add/discard/clear.

### Phase 8 — Polish

**T31. `Assert`, `Expr` wrapper, `Import math` silent-ignore, comprehensive UnsupportedNode coverage**
- `Assert(test, msg)` → `unless truthy?(test), do: raise(msg || "AssertionError")`.
- `Expr` value: drop expression result unless it's a recognised mutation (which T30 handles).
- `Import` with single name `"math"` → empty `__block__`. **`ImportFrom` with `module == "__future__"`** also → empty `__block__` (PEP 236 `from __future__ import ...` is a parse-time directive with no runtime effect; idiomatic Python 3.14 code routinely starts with `from __future__ import annotations`). All other `Import`/`ImportFrom` → `UnsupportedNodeError`. Everything else in §4.4-unsupported list → `UnsupportedNodeError` with explicit test per node type.
- **Full coverage matrix — every node in RFC §4.4 line 289 has an explicit test asserting `UnsupportedNodeError` with the right `_type`, hint, and source location.** Enumerated explicitly here so nothing slips:
  - **From RFC line 289**: `ClassDef`, `AsyncFunctionDef`, `AsyncFor`, `AsyncWith`, `ImportFrom`, `Import` (non-math), `Try`, `TryStar`, `ExceptHandler`, `With`, `Raise`, `Global`, `Nonlocal`, `Yield`, `YieldFrom`, `Await`, `Match`, `match_case`, `Delete`, `AnnAssign`, `TypeAlias`, `FormattedValue`, `JoinedStr`, `TemplateStr`, `Interpolation`, `Set` (literal), `NamedExpr` (walrus), `Starred` in assignment targets, `MatMult`.
  - **Additional (not in line 289 but real concerns)**: `Starred` in `Call.args`, **`Starred` in `List.elts`/`Tuple.elts`** (T08 rejection), slice-target assignment (`lst[1:3] = ...`), `Break`/`Continue` outside any loop, `Call.keywords` with non-whitelisted keyword (whitelist defined per builtin), Python identifiers matching `^var_` or `^py_` (T07's inverse-collision guard).
  - **Removed from unsupported** (per T24b): `GeneratorExp`, `SetComp`, `DictComp` — these now compile per the updated RFC §4.4.
- `Raise` and `Try` get especially helpful hint strings ("Use `raise/1` in Elixir via passthrough — not currently supported; will be added in a future ticket" — or whatever rationale the user prefers).
- Fill out the `@hints` table started in T03: every node-type in the coverage matrix gets a one-line hint string. Tests assert raised exception carries (a) the right `_type`, (b) the matching hint, (c) `lineno`/`col_offset` from the AST input.
- Final audit pass: each node type in §4.4 unsupported list **plus the additions above** must have a test that proves it raises with the right `_type` string, hint, and source location.
- Acceptance: full coverage matrix of unsupported nodes with hints + locations.

**T32. Golden test corpus**
- Pre-serialise the 12 algorithms in §11.2 (Python source + JSON AST + expected Elixir output) using `python3` 3.14.5.
- `priv/python/.python-version` pins to `3.14.5`. Each fixture's Python version recorded in a sidecar `.meta` file (or header comment if format allows).
- Add a regen script (`mix pylixir.regen_fixtures` or `priv/python/regen_fixtures.sh`) that walks `test/fixtures/python/*.py`, runs `serialize.py` on each, and writes the JSON. Idempotent.
- CI job runs the regen script, then `git diff --exit-code test/fixtures/` — fails if any maintainer pushed fixtures without regenerating.
- Test runner: for each fixture, run `to_source/1` on the JSON; compile+eval the result; capture stdout; assert stdout matches `expected_output.txt`. Also assert `Code.format_string!(output) |> IO.iodata_to_binary() == output` (formatter idempotency from T04 extended to the full corpus).
- Acceptance: all 12 fixtures green; CI regen-diff clean; formatter-idempotent on each; CI runs them.

### Phase 9 — Convenience wrapper

**T33. `priv/python/serialize.py` + `Pylixir.transpile/1`**
- Python script: reads source from argv/stdin, `ast.parse`, recursive `_type`-tagging serialiser, `json.dumps` to stdout. Mirrors §4.1 / §4.2 — **except keep `lineno` and `col_offset` on every node** (deviation from §4.2 strip; required by T03 error messages). Drop other location fields (`end_lineno`, `end_col_offset`) to keep JSON lean.
- **Python-side error handling**: wrap `ast.parse` + serialization in `try/except`. On `SyntaxError`: write a structured JSON to stdout — `{"error": "syntax", "message": str(e), "lineno": e.lineno, "col_offset": e.offset, "text": e.text}` — exit code 0 (so Elixir reads stdout deterministically). On any other exception: same shape, `"error": "internal"`, exit code 0. **Don't rely on exit codes** — explicit error envelope is more robust across shells.
- **Custom JSON encoder for unsupported `Constant` literals**: subclass `json.JSONEncoder` and override `default(self, obj)`:
  - `complex(...)` → `{"_unsupported_literal": "complex", "repr": str(obj)}`.
  - `bytes(...)` → `{"_unsupported_literal": "bytes", "repr": repr(obj)}`.
  - `obj is Ellipsis` → `{"_unsupported_literal": "ellipsis"}`.
  Without this, `json.dumps` would raise `TypeError` on these values and the whole serialization would fall into the generic "internal" error path — misleading, since the input parsed fine. The tagged shape is consumed by T06 which raises `UnsupportedNodeError` with a precise hint.
- Elixir wrapper: `System.cmd("python3", ["priv/python/serialize.py", ...])`. After `Jason.decode!`, **branch on `error` key**: if present, raise a new `Pylixir.PythonParseError` (struct with `:message`, `:lineno`, `:col_offset`, `:text`) carrying the structured fields; otherwise pass the AST to `to_source/1`.
- Add `:jason` to deps.
- Honour `PYLIXIR_PYTHON` env var override.
- `lib/pylixir/errors.ex` gains `Pylixir.PythonParseError` alongside `UnsupportedNodeError`.
- Acceptance:
  - `Pylixir.transpile("print(1+1)") |> compile+eval` prints `2`.
  - Negative-path: `Pylixir.transpile("class A: pass")` raises `UnsupportedNodeError` whose message contains `"at line 1"`.
  - **New negative-path**: `Pylixir.transpile("def )")` raises `Pylixir.PythonParseError` with a non-nil `:lineno` and the original message; assertion confirms it's NOT a `Jason.DecodeError`.
  - Test runs unconditionally on CI (3.14.5 is pinned in T02).

---

## Critical files to create (mapped to tickets)

| File | First introduced in |
|---|---|
| `mix.exs` | T01 |
| `lib/pylixir.ex` | T01 → expanded T04, T33 |
| `lib/pylixir/context.ex` | T03 |
| `lib/pylixir/errors.ex` | T03 |
| `lib/pylixir/converter.ex` | T03 (grows with every node ticket) |
| `lib/pylixir/runtime_helpers.ex` | T05 |
| `lib/pylixir/formatter.ex` | T04 |
| `test/support/transpile_helpers.ex` | T04b |
| `lib/pylixir/helpers_codegen.ex` (helper emission) | T05 |
| `lib/pylixir/naming.ex` | T07 |
| `lib/pylixir/nodes/literals.ex` | T06–T08 |
| `lib/pylixir/nodes/operators.ex` | T09–T12 |
| `lib/pylixir/nodes/statements.ex` | T13–T18 |
| `lib/pylixir/nodes/expressions.ex` | T15(IfExp), T21–T24 |
| `lib/pylixir/nodes/functions.ex` | T19–T21 |
| `lib/pylixir/builtins.ex` | T25a–T27 |
| `lib/pylixir/builtins/registry.ex` (shared dispatch table) | T25a |
| `lib/pylixir/ast/walk.ex` (shared scope-aware walk primitive) | T03 |
| `lib/pylixir/scope.ex` (for-loop analyzer; if extracted from Context) | T16a |
| `priv/python/serialize.py` | T33 |
| `.github/workflows/ci.yml` | T02 |

---

## Verification (end-to-end)

After T32 you can run, on any Python source in the supported subset:

```bash
echo 'print(sum(i*i for i in [1,2,3,4]))' \
  | python3 priv/python/serialize.py \
  | mix run -e 'IO.read(:stdio,:eof) |> Jason.decode!() |> Pylixir.to_source() |> IO.puts()' \
  | elixir -
```

(Sub `transpile/1` for the pipe after T33 is in.)

Per-ticket verification = the inline tests in that ticket + every prior ticket's tests still green.

---

## Unresolved questions

(none — all questions raised in the grilling session have been resolved)

## Resolved (during grilling session)

- **Helper emission strategy** — emit ALL helpers always; tree-shaking deferred. Generated module silences unused-function warnings via `@compile :nowarn_unused_functions`. (Conventions, T05)
- **Helper source-of-truth** — single source in `runtime_helpers.ex` as public `def`s (not `defp` — verified `@compile :nowarn_unused_functions` doesn't exist in Elixir; public functions are never warned-as-unused). Codegen reads it via `@external_resource` + `File.read!` at Pylixir's compile time and bakes the sliced text into a `@helpers_source` constant. Generated output stays fully self-contained string. (Conventions, T05)
- **`runtime_helpers.ex` distribution** — kept private. Not a public API.
- **Comprehension coverage** — `ListComp` in T24, `SetComp`/`DictComp`/`GeneratorExp` in T24b. Verification example needs T24b to actually run.
- **For-loop scope analysis** — split into T16a (pure analyzer, unit-tested in isolation) + T16b (codegen). Over-thread policy: loop var + every LHS name + root of subscript/attr targets. Reused by T17 and T18.
- **Additional unsupported nodes** — `Delete`, `Global`, `Nonlocal`, `Starred`-in-call, `AnnAssign`, `JoinedStr`/`FormattedValue`, `Yield`/`YieldFrom`, slice-target assignment all explicitly raise (T31).
- **Python 3.14.5 everywhere** — local + CI + fixtures all pinned to 3.14.5. T33 wrapper test runs unconditionally; no version-skipping. `priv/python/.python-version` pins it; CI uses `actions/setup-python@v5`.
- **Reserved-name policy (T07)** — Helpers use `py_<name>`; rewritten user identifiers use `var_<name>` (distinct namespaces). Three collision categories enumerated in `Pylixir.Naming`: hard keywords, special-form atoms, and `Kernel.__info__(:functions ++ :macros)` baked at Pylixir's compile time. Python identifiers matching `^var_` or `^py_` raise `UnsupportedNodeError`.
- **Error-message format** — `Pylixir.UnsupportedNodeError` carries `node_type`, `hint`, `lineno`, `col_offset`. Hint table in T03; filled out in T31. `serialize.py` deviates from RFC §4.2 by keeping `lineno`/`col_offset` (drops `end_*` variants).
- **Formatter round-trip guarantee** — Option B (self-consistency). Output must be a fixed point under the formatter Pylixir was compiled with. Tested in T04 (trivial) and T32 (full corpus). No promise about user `.formatter.exs` settings; README documents the caveat.
- **Compile-and-eval test infrastructure** — New T04b ticket: `Pylixir.TranspileHelpers` in `test/support/` provides `transpile_and_run/1` and `transpile_and_capture/1` that rewrite the generated `TranslatedCode` module to a unique atom per test, strip and re-issue the trailing `run()` call, compile via `Code.compile_quoted/1` wrapped in `Code.with_diagnostics/1` (Elixir 1.15+), and capture stdout via `ExUnit.CaptureIO`. Belt-and-braces `Code.compiler_options(ignore_module_conflict: true)` in `test_helper.exs`. Compile-and-eval tests can run `async: true`. `transpile_and_capture/1` asserts `diagnostics == []` internally so T05's "zero warnings" acceptance has a defined mechanism.
- **Chained `Compare` side-effect safety (T12)** — Option B (temps for non-trivial middles). `Pylixir.AST.trivial?/1` covers `Constant`/`Name`/`Attribute-of-trivial`. Middle operands failing the predicate are bound to `temp_<n>` in a `__block__`. Counter threaded via `Context.compare_counter`. Preserves Python's single-evaluation guarantee.
- **Scope-boundary walk primitive** — `Pylixir.AST.walk_scope/3` introduced in T03 stops at `FunctionDef`/`AsyncFunctionDef`/`Lambda`/`ClassDef`/`ListComp`/`SetComp`/`DictComp`/`GeneratorExp`. Consumed by T16a (assigned-vars), T19 (known_functions pre-pass), and T20 (return-in-loop detection). Single primitive, single set of boundary tests; T19/T20 each add a regression test confirming nested `def` doesn't leak across the boundary.
- **`If` codegen shape (T15)** — Three branches dispatched on `orelse`: empty → `if`; non-`If` → `if/else`; `[If(...)]` → flattened `cond` with mandatory `true -> nil` fallthrough when no terminal Python `else`. `truthy?` wrap skipped only when `Pylixir.AST.bool_returning?/1` is true (currently `Compare` only).
- **`throw`/`catch` tagging (T17/T18/T20)** — Namespaced atoms: `{:pylixir_break, acc}`, `:pylixir_continue`, `{:pylixir_return, value}`. All `catch` clauses use exact-tuple patterns (`catch :throw, {:pylixir_break, acc} -> acc`) so cross-throws propagate correctly. Acceptance includes `break-and-return-in-same-loop` and `continue-and-return-in-same-while` tests. `Break`/`Continue` outside a loop raise `UnsupportedNodeError` (defensive, added to T31).
- **Ticket size splits** — T25 → T25a (size + iteration shape: `len`/`range`/`sorted`/`reversed`/`enumerate`/`zip`) + T25b (aggregation + functional: `sum`/`min`/`max`/`abs`/`map`/`filter`). T29 → T29a (case + whitespace + prefix/suffix + `join`) + T29b (search + split + replace + classification). Shared `Pylixir.Builtins.Registry` lookup table feeds T25a/T25b/T26/T27 and T28's router.
- **Converter signature** — `convert(map(), Context.t()) :: {elixir_ast(), Context.t()}`. Already shipped in T03; locked in Conventions so every future node clause threads context explicitly. Forgetting to thread causes silent bugs in `while_counter`/`compare_counter`/scopes.
- **Single-evaluation guarantee across all multi-read patterns** — `Pylixir.AST.trivial?/1` (introduced in T12) is the central predicate. Applied uniformly in T12 (chained `Compare` middles), T13 (multi-target assign RHS), and T14 (`AugAssign` subscript value + slice). Non-trivial expressions are bound to a `py_tmp_<n>` once; trivial ones inline. Temp names use the `py_` prefix (collision-free with user Python identifiers per T07's `^py_` guard). Single `Context.temp_counter` shared across all three usage sites; no name reuse anywhere in the same function.
- **Comprehension scope deviation from RFC §4.4** — Plan supports `GeneratorExp`/`SetComp`/`DictComp` (T24b). RFC line 289 must be updated to reflect this; the RFC diff is part of T24b's PR. `GeneratorExp` is eager (not lazy) — documented in updated RFC.
- **T31 coverage matrix expansion** — Every node in RFC §4.4 line 289 enumerated explicitly with hint + location asserted. `Raise`/`Try` particularly visible to real users; given hint strings calling out future-work intent. Additional unsupporteds (slice-target assign, ^var_/^py_ user names) included.
- **Keyword-arg policy at call sites** — Whitelist, not blanket reject. Allowed: `sorted(key, reverse)` (T25a), `enumerate(start)` (T25a), `min/max(default)` (T25b), `print(sep, end)` (T27), `list.sort(key, reverse)` (T30). Everything else raises `UnsupportedNodeError` with the keyword name in the hint. Centralized router pattern: each builtin handler reads `Call.keywords` and validates against its own whitelist.
- **Return / tail-position rule (T20)** — Conservative wrap-iff: function body gets `try/catch` iff it has 2+ Returns OR 1 Return that's not the function's top-level last statement. Tail Return emits the value directly; all other Returns emit `throw({:pylixir_return, v})`. Covers the previously-missed non-loop-but-non-tail case (`if x: return 1; print(); return 2`).
- **Call routing precedence (T28)** — Local-scope shadowing checked FIRST, before any builtin or known-function lookup. `Context.scopes` stores Python names (the original AST identifier strings); T07's `var_<name>` rewrite is codegen-time only. Acceptance test: local lambda named `b` shadows top-level `def b(): ...`.
- **Self-passing transform (T21)** — Recursive nested defs detected via walk_scope over the nested-def body for self-referential `Call(func=Name(<inner_name>))`. When recursive: synthetic `self` param appended; in-body and outer-site calls rewritten to `inner.(args, self)`. Same transform for `Lambda` assigned to a name and referencing that name. Mutual recursion between nested defs raises `UnsupportedNodeError`.
- **Python-side error reporting (T33)** — `serialize.py` always exits 0 and emits a structured `{"error": "...", "message": "...", "lineno": ..., ...}` JSON envelope on parse failure. Elixir wrapper detects the `error` key and raises `Pylixir.PythonParseError` (new exception in `lib/pylixir/errors.ex`). Robust across shells; no `Jason.DecodeError` confusion when user passes invalid Python.
- **`float()` carve-out (T26)** — Literal `float("inf")`/`float("nan")` raises at translation time per RFC §564. Non-literal `float(x)` calls go through `py_float/1` (runtime `Float.parse`).
- **Tagged-shape JSON envelope for unsupported `Constant` literals (T33 ↔ T06)** — `serialize.py` custom-encodes `complex`/`bytes`/`Ellipsis` as `{"_unsupported_literal": kind, "repr": str}` shapes. T06 detects and raises a precise `UnsupportedNodeError`. Avoids `TypeError`-into-generic-internal-error chain.
- **`__name__` Python idiom (T07)** — `Name(id="__name__")` emits the literal string `"__main__"` rather than a variable reference. Makes the `if __name__ == "__main__":` idiom work; matches the spirit of generated `TranslatedCode.py_main()` being the script entry point.
- **Empty `assigned_vars` in `For` (T16b)** — Cardinality branch: 0 → `Enum.each`; 1 → reduce with bare acc; 2+ → reduce with tuple acc.
- **`While.orelse` non-empty raises (T18)** — Same convention as `For.orelse`.
- **`from __future__ import ...` silently ignored (T31)** — PEP 236 directive with no runtime effect; emit empty `__block__`. Same treatment as `import math`. Lets idiomatic `from __future__ import annotations` headers compile cleanly.
- **`def run` collision fix (T05)** — wrapper function renamed to `py_main` (under `^py_` protection). Output is `TranslatedCode.py_main()`; user `def run` is no longer a conflict.
- **Temp variable naming (T12/T13/T14)** — All single-eval temps use `py_tmp_<n>` (under `^py_` protection); single shared `Context.temp_counter`. Resolves the inconsistency between `temp_<n>` and `__tmp_<n>`.
- **`min/max(default)` resolved** — Supported via `Enum.min/2`'s fallback-fn form: `min(xs, default=0)` → `Enum.min(xs, fn -> 0 end)`. `key=` not in MVP. Closes T25b/Resolved contradiction.
- **No `import Bitwise` (T05/T11)** — Bitwise calls fully-qualified to avoid unused-import warning on bitwise-free programs.
- **`%` operator dispatched via `py_mod/2` helper (T11)** — Python's `%` is dual-meaning (numeric mod and string formatting). Helper detects binary left operand and raises with clear hint rather than letting `Integer.mod` `FunctionClauseError` leak. Same pattern as `py_add` for `+`.
- **`dict.get(k, default)` (T28)** — 2-arg form supported via `Map.get/3`. Native Elixir; no new mechanism.
- **`list.pop(i)` (T30)** — Explicit-index form supported via `List.pop_at/2`. Same two-statement emission as no-arg `pop()`.
- **`type_params` silently ignored (T19)** — PEP 695 generics (`def foo[T](x: T):`) have no Python runtime effect. Drop `type_params` via `Map.get(node, "type_params", [])`. Distinct from `decorator_list` which is rejected because decorators are runtime-semantic.
- **Module-body partitioning for top-level constants (T05/T07/T19)** — Critical: defp's at module level can't see py_main's locals, so the common Python pattern `PI = 3.14; def area(r): return PI * r * r` would otherwise fail to compile. Fix: partition `Module.body` into (a) `FunctionDef` → defp's, (b) literal-RHS top-level Assigns → `@var_<name>` module attributes, (c) everything else → inside `py_main`. T07's `Name` converter emits `@var_<name>` for tracked module attrs. Reassigning a module-attr name anywhere raises. Function bodies referencing non-literal top-level vars raise with hint suggesting parameter-passing.
- **`Starred` in list/tuple literals (T08)** — rejected for MVP with hint suggesting `xs + [...]` rewrite. Added to T31 coverage matrix.
- **T28 `Attribute` fallthrough fix** — Unknown `Attribute(value, attr)` calls raise `UnsupportedNodeError` with the method name in the hint, NOT emit-as-is. Prevents `name.format("x")` becoming a broken remote-call. Unknown `Name` calls still emit as-is (preserves Python `NameError` ergonomics).
