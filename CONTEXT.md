# Pylixir Domain Vocabulary

Glossary of terms that appear in code, tests, plan, and docs. Architecture
reviews and grilling sessions should use these terms verbatim — drift
into "service", "component", or "boundary" is a smell.

## Domain terms

**Python AST (input)** — A decoded-JSON map produced by Python's
`ast.parse` and a custom serializer (T33). Always rooted at a Python
`Module` node with a `body` list. Each node carries a `_type` string,
optional `lineno`/`col_offset`, and node-type-specific fields.

**Elixir AST (intermediate)** — The 3-tuple form (`Macro.t()`) that
Pylixir builds and `Code.format_string!` renders into source text.

**Generated output** — A self-contained Elixir source string consisting
of `defmodule TranslatedCode do ... end` plus a trailing
`TranslatedCode.py_main()` call. Contains every helper Pylixir might
need; runs without depending on Pylixir at runtime.

**Module body** — The `body` list on a Python `Module` AST node. The
input to `Pylixir.ModuleAnalysis.analyze/1`. Distinct from the *Elixir*
defmodule body that Pylixir emits.

**Module analysis** — The static analysis that runs once over a Python
Module body before per-statement conversion. Lives in
`Pylixir.ModuleAnalysis`; produces a struct with four facts:

  * **Module attrs** — Top-level literal `Assign`s whose target is
    never mutated downstream. Emitted as `@var_<name>` Elixir module
    attributes (T05). The `Context.module_attrs` MapSet of names lets
    T07's `Name` converter emit `@var_<name>` instead of `var_<name>`.
  * **Function defs** — Top-level `FunctionDef` nodes. Emitted as
    `defp`s at module level (T19).
  * **Runtime statements** — Everything else in `Module.body`,
    including literal Assigns that *were* mutated later. Goes into
    `py_main`'s body in original order.
  * **Known functions** — Set of top-level `FunctionDef` names, seeded
    into `Context.known_functions` so call sites can forward-reference
    functions defined later in the source (RFC §10.3).

**Mutation scan / Pass 1** — The first pass of `analyze/1`. Walks every
top-level statement via `Pylixir.AST.Walk.walk_scope/3` looking for
reassignments / augmented assignments / subscript writes / mutation
methods / for-loop rebinds that target each literal-Assign candidate.
The walker stops at nested function/lambda/class/comprehension
boundaries because those have their own `name` bindings in Python.

**Partition / Pass 2** — The second pass. Classifies each top-level
statement into one of three buckets (module_attrs, function_defs,
runtime_statements) using the mutation-free set from Pass 1.

**Wrapper (module wrapper)** — The `defmodule TranslatedCode do ... end`
shape Pylixir emits. Owns helpers, module attrs, defp's, and the
`def py_main` entry point. Built by `Pylixir.Converter`'s Module clause.

**Helper** — A `py_*` function spliced into every generated module so
the output is self-contained. Source of truth is
`Pylixir.RuntimeHelpers`; baked into `@helpers_source` by
`Pylixir.HelpersCodegen` at Pylixir's own compile time. The
`py_*` prefix is the load-bearing emission namespace: any AST tuple
literal `{:py_*, [], args}` appearing in `Pylixir.Builtins`,
`Pylixir.Converter`, or a `Pylixir.Stdlib` impl must resolve to a
helper of matching arity. The helpers-linkage test
(`test/pylixir/helpers_linkage_test.exs`) enforces this statically via
`HelpersCodegen.helper_names/0`, so a rename or typo surfaces at
Pylixir's test time rather than in user code at runtime.

**Entry point** — The `def py_main` function at the bottom of the
wrapper. `py_main` because the `py_` prefix is protected by T07's
collision rules, so a user's `def run():` will never collide.

**Context** — Threaded state during conversion (`Pylixir.Context`).
Fields: `scopes`, `while_counter`, `loop_nesting`, `known_functions`,
`temp_counter`, `module_attrs`, `def_position`. Every `convert` clause
takes a Context and returns the (updated) Context.

**Single-evaluation temp** — A `py_tmp_<n>` binding emitted by T12, T13,
or T14 when an expression needs to be evaluated exactly once but
referenced multiple times in the generated Elixir (Python's single-eval
semantics). Counter is `Context.temp_counter`. The `py_` prefix is
protected by T07.

**Walk_scope boundary** — `Pylixir.AST.Walk.walk_scope/3` treats
`FunctionDef`, `AsyncFunctionDef`, `Lambda`, `ClassDef`, `ListComp`,
`SetComp`, `DictComp`, and `GeneratorExp` as scope barriers — it visits
the boundary node but does not descend into its body. Reflects Python's
scoping: names assigned inside those constructs are scope-local and do
not leak.

**Lowering** — The `{:ok, ast} | {:error, hint} | :no_clause` result
tuple returned by `Pylixir.Builtins.emit/3` and every
`Pylixir.Stdlib.<Module>.call/4` / `.attribute/2`. Describes the
outcome of translating a single Python expression. Consumed by
`Pylixir.Lowering.dispatch/4`, which either returns `{ast, context}`
or raises `UnsupportedNodeError`. The shared *result type* (not a
shared behaviour) is what lets the hardcoded-builtin surface and the
pluggable stdlib registry be dispatched by one helper without
conflating their distinct roles.

**Stdlib registry** — `Pylixir.Stdlib` holds a compile-time map from
Python module name (`"math"`, `"sys"`) to its implementing module
(`Pylixir.Stdlib.Math`, `Pylixir.Stdlib.Sys`). Implementations
`@behaviour Pylixir.Stdlib` and define `attribute/2` + `call/4`, both
returning a [[Lowering]] result. Adding a new stdlib module = one new
file + one `@implementations` entry. The Converter discovers entries
via `supported?/1` (Import gate) and `impl/1` (Attribute / Call
dispatch via `stdlib_chain/1`).

**Node module** — Files under `lib/pylixir/nodes/<x>.ex` that own the
lowering for a related group of Python AST node types: `Comprehension`
(list/set/dict/generator), `Loop` (For/While/Break/Continue),
`Functions` (FunctionDef/Lambda), `If` (if/elif/else), `Compare`
(single + chained), `Mutations` (statement-context `.append`/`.sort`
…), `AttributeMethods` (instance method dispatch). The Converter's
`convert/2` clauses delegate to the matching node module; cross-node
mechanics (`convert_each`, `convert_keywords`, `convert_loop_target`,
`convert_test`, `bind_name`, `body_to_block`, `tuple_pattern`,
`next_temp`, `maybe_temp_bind`, `var_bound?`, `name_in_scope?`) stay
on `Pylixir.Converter` as `@doc false` public functions because every
node module calls back through them. Mirrors the long-standing
`test/pylixir/nodes/<x>_test.exs` layout.

**Control-flow protocol** — `Pylixir.ControlFlow` owns the throw/catch
shapes that Pylixir uses to implement Python's early-exit constructs:

  * `return value` → `{:pylixir_return, value}` (caught by the
    function body's wrapper when `Context.return_mode == :wrapped`).
  * `break` → `{:pylixir_break, payload}` (caught by the enclosing
    loop).
  * `continue` → `{:pylixir_continue, payload}` (caught by the
    enclosing loop's per-iteration arm).
  * `exit(code)` / `sys.exit(code)` → `{:pylixir_exit, code}` (caught
    by py_main's wrapper, which returns the code).

`throw_*/1` and `catch_*/2` constructors build the matching emit-side
and catch-side AST shapes. Without this module the atoms were
duplicated across ~10 emit sites and ~6 catch sites; any tuple-shape
change would have needed synchronised edits across multiple files.
