# Plan: pylixir — Python AST → Elixir transpiler (greenfield)

## Context

Repo is empty (`docs/rfc.md` only). RFC-001 v10 specifies an Elixir library:
`Pylixir.to_source/1` takes a Python AST as decoded-JSON map, returns Elixir source string. Optional `Pylixir.transpile/1` shells out to `python3` for convenience.

Local env: Elixir 1.19.5 / OTP 28 ✓ (RFC needs 1.19+/26+). Python 3.13 local (RFC asks 3.14+ for wrapper — fine for fixtures, runtime wrapper test deferred).

Goal of this plan: ordered list of ~33 small tickets (≈ ½–1 day each), each shippable as its own PR. Tests live inline with each ticket. Each ticket lists the RFC section(s) it depends on plus the edge-case traps it must handle.

Output ordering follows §12 of the RFC but splits the fat steps. Helpers (`truthy?`, `py_add`, …) are introduced exactly when the first node needing them is implemented, then extended.

---

## Conventions

- Every ticket ends with `mix test` green + `mix format --check-formatted` green.
- Helpers are emitted as `defp` *inside* the generated module (§9). For testability, also live verbatim in `lib/pylixir/runtime_helpers.ex` so ExUnit can call them directly. Codegen reads the source of that module (or has a string constant) for emission.
- Codegen emission policy for MVP: **emit ALL helpers in every output module**. Tree-shaking is a later optimization, not a ticket.
- Every node that's "out of scope" must raise `Pylixir.UnsupportedNodeError` with the `_type` string — never silently drop.

---

## Tickets

### Phase 0 — Project skeleton

**T01. `mix new` + repo layout**
- `mix new pylixir --module Pylixir`
- Add `priv/python/`, `test/fixtures/python/`, `test/fixtures/elixir/`, `lib/pylixir/nodes/` directories (with `.gitkeep`).
- Top-level `Pylixir` module with stub `to_source/1` returning `""`.
- `README.md` with 1-paragraph summary + link to RFC.
- `.gitignore` (defaults + `/tmp/`).
- Acceptance: `mix test` runs (one trivial test); `mix compile` warns about nothing.

**T02. CI + tooling**
- `.github/workflows/ci.yml`: Elixir 1.19 / OTP 28 matrix; run `mix deps.get`, `mix format --check-formatted`, `mix test`, `mix credo --strict`.
- Add `:credo` to deps (dev/test only). (Skip `:dialyxir` — opt-in later if useful.)
- `.formatter.exs` already created by `mix new`; verify.
- Acceptance: green CI on a no-op push.

**T03. Errors + Context struct + dispatch skeleton**
- `lib/pylixir/errors.ex`: `Pylixir.UnsupportedNodeError` with `node_type` field.
- `lib/pylixir/context.ex`: struct per §10.2 (`scopes`, `while_counter`, `loop_nesting`, `known_functions`).
- `lib/pylixir/converter.ex`: `convert/2` with a single catch-all clause that raises `UnsupportedNodeError` for any `%{"_type" => t}` (the white-list grows ticket by ticket).
- Acceptance: unit test that `convert(%{"_type" => "ClassDef"}, ctx)` raises with `node_type: "ClassDef"`.

**T04. Formatter pipeline + `Pylixir.to_source/1` entry**
- Implement §10.11 exactly: `Macro.to_string |> Code.format_string! |> IO.iodata_to_binary`. Trap: don't drop the iodata step (§3.1).
- `to_source/1` calls `collect_function_names/1` (§10.3) and seeds `Context`.
- Acceptance: round-trip `quote do: 1 + 2` through the pipeline; assert binary string output.

**T05. Module wrapper + helpers injection**
- `Module` node → `defmodule TranslatedCode do import Bitwise; <helpers...>; <body>; def run, do: <run-body> end` + trailing `TranslatedCode.run()` (§3.4).
- `lib/pylixir/runtime_helpers.ex`: hand-write every helper from §9 (used both for emission source and for direct testing).
- Add ExUnit tests that exercise each helper directly (§11.3 cases for `truthy?`, `py_add`, `py_str`, `py_round`, `py_hex`, `py_str_count`, boolean arithmetic, MapSet truthiness).
- Acceptance: `to_source/1` on empty `Module` produces compiling Elixir source (compile-and-eval it from the test).

### Phase 1 — Literals + variables

**T06. `Constant` node**
- int / float / str / bool / nil → self-representing Elixir literals (post-JSON-decode bool/None become Elixir `true`/`false`/`nil`).
- Reject complex (map shape), bytes (binary marker), Ellipsis → raise.
- Acceptance: parametrised tests for each Python literal type.

**T07. `Name` node**
- `Name` → `{:name_atom, [], nil}` 3-tuple.
- Reserved-name handling: if id collides with Elixir builtin (`if`, `do`, `end`, `when`, …), emit with a deterministic prefix (`py_<id>`). Audit list lives in `Pylixir.Naming`.
- Acceptance: tests for plain ids and reserved ids.

**T08. `List`, `Tuple`, `Dict` literals**
- `List` → Elixir list AST.
- `Tuple` → 2-tuple literal for n=2, `{:{}, [], elts}` for n≠2 (§5.2).
- `Dict` → `%{}` map AST; reject any entry where `keys[i] == nil` (dict-unpack) with `UnsupportedNodeError`.
- Acceptance: nested literals, empty collections.

### Phase 2 — Operators

**T09. `UnaryOp`**
- `UAdd` (no-op), `USub` (`-x`), `Invert` (`~x` → `Bitwise.bnot/1`), `Not` (`!truthy?(x)` — depends on helper from T05; ok since helpers are always emitted).
- Acceptance: each unary op tested.

**T10. `BinOp` arithmetic (Add, Sub, Mult, Div, Pow)**
- `Add` → `py_add/2`; `Mult` → `py_mult/2`; `Pow` → `py_pow/2`; `Sub` → `-`; `Div` → `/`.
- Edge cases (§6.8 string concat, §6.9 list/string repeat, §6.10 float-vs-int pow, §6.11 boolean arithmetic).
- Acceptance: integration test that compiles + evals output for each case; matches Python results.

**T11. `BinOp` floor-div, mod, bitwise**
- `FloorDiv` → `Integer.floor_div/2` (§6.1). `Mod` → `Integer.mod/2` (§6.2).
- `LShift`/`RShift`/`BitOr`/`BitAnd` → `<<<`/`>>>`/`|||`/`&&&` (Bitwise already imported).
- `BitXor` → `Bitwise.bxor/2` (§6.22 — never `^^^`).
- Reject `MatMult`.
- Acceptance: tests for negative-operand floor-div and mod.

**T12. `BoolOp` + `Compare` (with chaining)**
- `BoolOp` (`And`/`Or`) → `&&`/`||` over the `values` list (§5.3, §6.3 caveat).
- `Compare` → fold ops + comparators into `&&`-chain (§6.4). Wrap a single comparator pair as a plain binary op.
- `In`/`NotIn` → `py_in/2` (and `!` for NotIn). `Is`/`IsNot` → `==`/`!=` (§10.10).
- Optimization: `if`/`while` conditions whose root is `Compare` skip `truthy?` wrap (later — T15).
- Acceptance: tests including `1 < x < 10`, `x in [...]`, `x is None`.

### Phase 3 — Assignment

**T13. `Assign` (simple, multi-target, tuple unpack)**
- Single `Name` target → `target = value`.
- Multiple targets (`a = b = 5`) → emit a `__block__` of separate assigns.
- `Tuple` target → `{a, b} = {b, a}` style (§10.9). Reject `Starred` in target.
- Update `Context.scopes` to record bound names.
- Acceptance: tests for each shape, plus tuple swap.

**T14. `AugAssign` (all ops + subscript targets)**
- Per §7.2 table. Subscript target → `py_setitem/py_getitem` rewrite (§7.3).
- Acceptance: covers `x += 1`, `d[k] += 1`, `lst[i] *= 2`, all bitwise/arith ops.

### Phase 4 — Control flow

**T15. `If`/`Pass`/`IfExp`**
- All `If` chains → `cond` (§10.7). Plain `if` with no `else` → `if`.
- Pass → `:ok` literal (no-op).
- `IfExp` ternary → `if test, do: body, else: orelse` (note argument order §AST 4.4).
- Wrap condition in `truthy?/1` unless it's a `Compare` node (cheap optimisation from T12 lands here).
- Acceptance: nested if/elif/else, ternary, empty body.

**T16. `Break`/`Continue` + for-loop core (no break/continue body yet)**
- Only the `For` node *without* break/continue/return in body. `Enum.reduce/3` with tuple accumulator threading every mutated var (§10.4). Read-only externals stay captured.
- `For.orelse` non-empty → raise.
- Scope analysis: walk body to collect `assigned_vars`; conservative MVP per §10.4.
- Acceptance: sum-of-list, multi-var loops.

**T17. For-loop with `break` / `continue`**
- `continue` → return accumulator unchanged (terminate fn arrow). `break` → `throw({:break, acc})` wrapped in `try/catch`.
- Acceptance: loop that breaks mid-way, loop with continue filter.

**T18. `While` loop (recursive helper)**
- §10.5 template. Each `While` becomes `defp while_<n>(...)` (counter in Context). Returns final state tuple. Caller pattern-matches `{vars...} = while_n(...)`.
- Handle `break` and `continue` (recurse / throw-catch).
- Acceptance: loop convergence, break, continue.

### Phase 5 — Functions

**T19. `FunctionDef` + `arguments` + `arg` + defaults**
- Pre-pass collects names → `Context.known_functions` (already in T04 — verify hook works).
- Emit `defp name(args), do: body` (use `do:` short-form when body is one expression).
- Defaults via `{:\\, [], [param_ast, default_ast]}` (§5.2). Defaults apply to LAST n args.
- Reject `vararg`, `kwarg`, `kwonlyargs`, non-empty `decorator_list`, `posonlyargs`.
- New scope frame in Context; pop on exit.
- Acceptance: function with defaults, recursive function, forward reference.

**T20. `Return` + return-inside-loop (try/throw/catch)**
- Tail-position return inside `cond` branches: just emit the value.
- Return inside any loop body: wrap whole function body in `try do … throw({:return, value}) … catch {:return, v} -> v end` (§10.6). Detection via AST walk of FunctionDef body.
- Bare `return` → `throw({:return, nil})` or `nil` if tail-position.
- Acceptance: `find_first` example from §10.6; multiple returns; early return inside nested if.

**T21. `Lambda` + nested `FunctionDef`**
- `Lambda` → `fn args -> body end`.
- Nested `def` inside another `def` → bind as anonymous `fn` (§10.8). Recursive inner uses self-passing pattern.
- Acceptance: nested `def`, lambda with default arg, recursive inner.

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

### Phase 7 — Builtins + methods

**T25. Builtins: iteration primitives**
- `len` → `py_len`. `range` (all three arities incl. negative step §6.17). `sorted`, `reversed`, `enumerate` (note `{x, i}` swap §6.5), `zip` (2-arg + n-arg), `map`, `filter`, `sum`, `min`/`max` (1-iter vs n-args), `abs` → `py_abs`.
- Routing: `Call.func` is `Name` and id is in this table → emit mapped form.
- Acceptance: each builtin tested via end-to-end compile+eval.

**T26. Builtins: conversions + type checks**
- `int`/`float`/`str`/`bool`/`list`/`tuple`/`set`/`dict` per §8 table.
- `type(x) == T` and `isinstance(x, T)` per §8 table, incl. tuple-of-types form and the `isinstance(x, int)` ⇒ `is_integer(x) || is_boolean(x)` fix (§6.13).
- Acceptance: each conversion + each type-check predicate; `isinstance(True, int) == true`.

**T27. Builtins: IO + numeric formatting + rounding**
- `print()` no-args, single, multi (§8 — `Enum.join` of `py_str`'d args).
- `input(prompt)` → `py_input`.
- `chr`/`ord`/`hex`/`oct`/`bin` per §8 (note `hex(-255)` → `"-0xff"` §6.7-adjacent).
- `round(x)` and `round(x, n)` → `py_round` (banker's §6.14).
- `divmod`, `any`, `all` (latter two need `&truthy?/1` — §16 #23).
- `math.*` table: detect `Attribute` with `value.id == "math"` (§10.1). Module-level `import math` silently produces no code; all other imports raise.
- `math.inf`/`math.nan` raise (§6.19).
- Acceptance: each builtin; print of bool/None/list/tuple/dict matches Python str()/repr().

**T28. `Attribute` dispatch + dict/list/set/string method routing**
- Centralised `Call` handler picks among: math builtin, mutation method (§7.4) iff parent is `Expr` (statement context), expression-level method (§7.5), regular builtin, known local function, unknown remote call (emit as-is).
- This ticket implements just the *router* + dict methods (`items`, `keys`, `values`, `get`) since they're simplest.
- Acceptance: routing tests covering each branch; dict method evaluations.

**T29. String methods**
- Full §7.5 string-methods table (lower/upper/strip/lstrip/rstrip/startswith/endswith/split incl. maxsplit form/replace incl. count=1 form §6.23/find/count/index/zfill/isdigit/isalpha/isalnum).
- `sep.join(items)` arg-swap (§10.1).
- Reject multi-char `strip(chars)` (§6.24), `count > 1` to `replace` (§6.23), `split("")` documented divergence (§6.20).
- Helpers `py_str_find`, `py_str_count` already in T05 — extend if needed.
- Acceptance: per-method tests.

**T30. List/dict/set mutation methods + expression-context pop**
- Statement-context (`Expr`-wrapped) mutations rewrite to `x = …` per §7.4 table.
- Special `pop()` in assignment context (§7.4 note): emits `removed = Enum.at(...); x = List.delete_at(...)` as two statements via `__block__`.
- `list.remove` documented (returns unchanged when not found).
- Acceptance: append, sort variants, pop in both contexts, dict.update, MapSet.add/discard/clear.

### Phase 8 — Polish

**T31. `Assert`, `Expr` wrapper, `Import math` silent-ignore, comprehensive UnsupportedNode coverage**
- `Assert(test, msg)` → `unless truthy?(test), do: raise(msg || "AssertionError")`.
- `Expr` value: drop expression result unless it's a recognised mutation (which T30 handles).
- `Import` with single name `"math"` → empty `__block__`. Everything else in §4.4-unsupported list → `UnsupportedNodeError` with explicit test per node type.
- Final audit pass: each node type in §4.4 unsupported list must have a test that proves it raises with the right `_type` string.
- Acceptance: full coverage matrix of unsupported nodes.

**T32. Golden test corpus**
- Pre-serialise the 12 algorithms in §11.2 (Python source + JSON AST + expected Elixir output) using the local `python3` (Python 3.13 is fine for the AST shape we need).
- Test runner: for each fixture, run `to_source/1` on the JSON; compile+eval the result; capture stdout; assert stdout matches `expected_output.txt`.
- Acceptance: all 12 fixtures green; CI runs them.

### Phase 9 — Convenience wrapper

**T33. `priv/python/serialize.py` + `Pylixir.transpile/1`**
- Python script: reads source from argv/stdin, `ast.parse`, recursive `_type`-tagging serialiser, `json.dumps` to stdout. Mirrors §4.1 / §4.2 (strip lineno etc.).
- Elixir wrapper: `System.cmd("python3", ["priv/python/serialize.py", ...])`, `Jason.decode!`, `to_source/1`. Add `:jason` to deps.
- Honour `PYLIXIR_PYTHON` env var override.
- Skip wrapper integration test on CI if `python3 -c 'import sys; sys.exit(0 if sys.version_info>=(3,14) else 1)'` fails — keep it local-only until 3.14 is around.
- Acceptance: `Pylixir.transpile("print(1+1)") |> compile+eval` prints `2`. Skipped tag for Python<3.14.

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
| `lib/pylixir/helpers_codegen.ex` (helper emission) | T05 |
| `lib/pylixir/naming.ex` | T07 |
| `lib/pylixir/nodes/literals.ex` | T06–T08 |
| `lib/pylixir/nodes/operators.ex` | T09–T12 |
| `lib/pylixir/nodes/statements.ex` | T13–T18 |
| `lib/pylixir/nodes/expressions.ex` | T15(IfExp), T21–T24 |
| `lib/pylixir/nodes/functions.ex` | T19–T21 |
| `lib/pylixir/builtins.ex` | T25–T27 |
| `lib/pylixir/scope.ex` (if extracted from Context) | T16 |
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

1. **Helper emission strategy** — emit ALL helpers always (chosen above, MVP-simple) vs. track-and-shake. Confirm MVP-always is fine even when output gets ~150 LOC of unused helpers per module?
2. **`Pylixir.UnsupportedNodeError` message format** — include the offending `_type` only, or also a hint string per node (more dev-friendly, more strings to write)?
3. **`runtime_helpers.ex` distribution** — the file exists for testing, but should it also be public API (`Pylixir.Helpers`) for users who want to call helpers from non-generated code? Recommendation: keep private (no public docs).
4. **Reserved-name list (T07)** — exact list of Python identifiers that collide with Elixir keywords needs to be enumerated. Punt to T07 itself (audit at implementation time) or pre-decide now?
5. **Python 3.13 vs 3.14 for fixtures** — T32 uses local 3.13. If anything in §4.4 fixtures relies on 3.14-only AST shapes, we'd discover late. Acceptable risk, or generate fixtures externally on 3.14?
6. **`mix format` for generated output** — current pipeline (§3.1) uses `Code.format_string!` which is the same as `mix format`. Confirm output should always pass `mix format --check-formatted` round-trip on the generated `TranslatedCode` module too?
