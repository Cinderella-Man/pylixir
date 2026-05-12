# RFC-001: pylixir — Python AST to Elixir Transpiler

**Status:** Implementation-Ready (v10)
**Created:** 2026-05-09
**Revised:** 2026-05-12 (v10 — consolidated single-file RFC; targets Python 3.14 and Elixir 1.19/OTP 26+; all claims verified against official documentation)

---

## §1. Executive Summary

### 1.1 What Is pylixir?

`pylixir` is an Elixir library that converts Python Abstract Syntax Trees (ASTs) — represented as decoded JSON maps — into working Elixir source code. It is a pure function: map in, string out.

```elixir
python_ast = %{
  "_type" => "BinOp",
  "left" => %{"_type" => "Constant", "value" => 1},
  "op" => %{"_type" => "Add"},
  "right" => %{"_type" => "Constant", "value" => 2}
}

Pylixir.to_source(python_ast)
# => "1 + 2"
```

The library does not read files, does not do batch processing, does not run tests. It accepts a Python AST map, converts it to an Elixir AST (quoted expression tuples), and formats that AST into a source code string.

### 1.2 API Surface

Two entry points:

- **`Pylixir.to_source/1`** — the core API. Accepts a Python AST map (already decoded from JSON), returns an Elixir source code string. Pure function, no external dependencies.

- **`Pylixir.transpile/1`** — convenience wrapper for interactive use. Accepts a Python source string, shells out to `python3` to parse via `ast.parse()` and serialize to JSON, decodes, then calls `to_source/1`. **Requires Python 3.14+ on the system PATH.**

```elixir
# Core API — no Python dependency
Pylixir.to_source(%{"_type" => "Module", "body" => [...]})
# => "defmodule TranslatedCode do ... end\n\nTranslatedCode.run()"

# Convenience wrapper — requires Python 3.14+ on PATH
Pylixir.transpile("def add(a, b): return a + b\nprint(add(3, 4))")
# => "defmodule TranslatedCode do ... end\n\nTranslatedCode.run()"
```

### 1.3 Target Versions

| Component | Version | Notes |
|-----------|---------|-------|
| **Python AST input** | 3.14+ | `ast.Constant` is the only literal node. `ast.Num`, `ast.Str`, `ast.Bytes`, `ast.NameConstant`, and `ast.Ellipsis` were removed in 3.14. |
| **Elixir output** | 1.19+ | Requires OTP 26+. Uses `Integer.floor_div/2`, `Integer.mod/2`, `Bitwise.bxor/2`, `Code.format_string!/1`. |
| **Erlang/OTP** | 26+ | Maps use HAMT with non-deterministic iteration order across VM restarts. `MapSet` backed by `:sets` v2. |

### 1.4 What "Working, Not Idiomatic" Means

The output is **working, not idiomatic** Elixir. The goal is correctness — code that compiles and produces the same results as the Python original. It will not be pretty. It will use `Enum.reduce` where a human would write `Enum.map`. It will generate helper functions for `while` loops. It will produce `{result}` tuple accumulators for single-variable loops. Performance characteristics may differ (e.g., list indexing with `Enum.at/2` is O(n) rather than O(1)). This is acceptable — the goal is behavioral correctness, not algorithmic complexity preservation.

### 1.5 Target Use Case

Self-contained algorithmic code: sorting algorithms, dynamic programming, graph traversals, mathematical computations, string manipulation, and similar standalone logic found in coding challenges and small utility functions.

### 1.6 Design Philosophy

1. **Correctness over elegance.** Every construct must produce the same result as Python, including edge cases (negative modulo, floor division, truthiness, banker's rounding).
2. **Explicit over implicit.** When semantics diverge, the generated code makes the divergence explicit (e.g., `Integer.floor_div/2` instead of `div/2`).
3. **Runtime dispatch over static type inference.** When translation depends on operand type (e.g., `+` for numbers vs strings), the generated code uses runtime-dispatching helpers (`py_add/2`, `truthy?/1`).
4. **Fail loudly on unsupported constructs.** Raise `UnsupportedNodeError` for anything not handled. Never produce silent wrong code.
5. **No Python dependency at runtime.** The core `to_source/1` API receives pre-parsed ASTs. Python is used only offline or via the optional `transpile/1` wrapper.

---

## §2. Scope

### 2.1 In Scope

Self-contained algorithmic code that uses:

- **Literals:** integers, floats, strings, booleans, `None`, lists, tuples, dicts
- **Variables:** assignment, augmented assignment, rebinding
- **Operators:** arithmetic, comparison, boolean, bitwise
- **Control flow:** `if`/`elif`/`else`, `for` loops, `while` loops, `break`, `continue`, `pass`
- **Functions:** `def`, `return`, default arguments, `lambda`
- **Comprehensions:** list comprehensions (with filters)
- **Slicing:** `x[1:3]`, `x[::-1]`, `x[::2]`
- **Dict iteration:** `dict.items()`, `dict.keys()`, `dict.values()`
- **Builtins:** `len`, `range`, `abs`, `min`, `max`, `sorted`, `sum`, `enumerate`, `zip`, `int`, `float`, `str`, `print`, `list.append`, `dict.get`, string methods, etc.
- **Nested functions:** inner `def` converted to anonymous functions
- **Early returns:** `return` inside `if` blocks (via `try`/`throw`/`catch`)
- **Tuple unpacking:** `a, b = b, a`

### 2.2 Out of Scope

| Category | What's excluded | Why |
|----------|----------------|-----|
| **OOP** | Classes, inheritance, decorators, `super()` | No Elixir equivalent; requires full object system |
| **Async** | `async def`, `await`, `async for`, `async with` | Elixir uses processes/GenServer, not async/await |
| **Imports** | `import`, `from X import Y` | Module systems fundamentally different. **Exception:** `import math` silently ignored since math functions are pre-mapped (§10.1) |
| **I/O** | `open()`, `read()`, `write()`, file operations | Beyond algorithmic translation scope |
| **Exceptions** | `try`/`except`/`finally`, `raise` with custom types | Mapping Python's exception hierarchy is a separate project |
| **Generators** | `yield`, `yield from`, generator expressions | No direct Elixir equivalent |
| **Context managers** | `with` statement | No direct Elixir equivalent |
| **Standard library** | `os`, `sys`, `json`, `re`, `collections`, `itertools` | Per-module mapping needed; only basic builtins supported |
| **Global/nonlocal** | `global x`, `nonlocal x` | Scope manipulation that doesn't translate |
| **Delete** | `del x`, `del x[i]` | No Elixir equivalent for mutable deletion |
| **AnnAssign** | `x: int = 5` | Type annotations not part of Elixir runtime |
| **Match** | `match`/`case` (Python 3.10+) | Complex pattern matching needing its own rules |
| **F-strings** | `f"hello {name}"` | String interpolation with embedded expressions |
| **Walrus operator** | `:=` (named expressions) | No Elixir equivalent |
| **Star expressions** | `*args`, `**kwargs` in function definitions | No direct Elixir equivalent |

---

## §3. Architecture and Pipeline

### 3.1 Pipeline Overview

```
Input map (Elixir map with "_type" keys)
  → Pylixir.Converter.convert/2 (recursive dispatch, threads Context)
  → Elixir AST (quoted expression tuples)
  → Macro.to_string/1 (→ binary string)
  → Code.format_string!/1 (→ iodata, NOT a binary)
  → IO.iodata_to_binary/1 (→ final binary string)
```

**CRITICAL:** `Code.format_string!/1` returns `iodata()`, NOT a binary string. The Elixir docs confirm: the typespec is `@spec format_string!(binary, keyword) :: iodata`. The pipeline MUST end with `IO.iodata_to_binary/1`. String operations like `String.length/1` or pattern matching will fail on raw iodata.

```elixir
# CORRECT pipeline:
ast
|> Macro.to_string()        # returns binary string
|> Code.format_string!()    # returns iodata (NOT binary!)
|> IO.iodata_to_binary()    # returns binary string

# WRONG — result is iodata, String operations will fail:
ast |> Macro.to_string() |> Code.format_string!()
```

### 3.2 The `convert/2` Function

The core recursive dispatcher. Takes a Python AST node (map with `"_type"` key) and a context struct, returns `{elixir_ast, updated_context}`.

```elixir
@spec convert(node :: map(), context :: Pylixir.Context.t()) :: {Macro.t(), Pylixir.Context.t()}
def convert(%{"_type" => type} = node, context) do
  # dispatch to type-specific clause
end
```

One recursive walk, one output. No intermediate representation, no multi-pass compilation, no optimization.

### 3.3 Why Elixir AST as Intermediate?

Benefits of building Elixir AST tuples (the same format `quote` produces) instead of strings directly:

- `Macro.to_string/1` handles operator precedence, `do/end` blocks, parentheses
- `Code.format_string!/1` applies `mix format` rules automatically
- `Code.eval_quoted/2` can evaluate the AST directly for testing
- The AST is composable — build small pieces, nest naturally

**Gotcha:** `Macro.to_string/1` produces syntactically valid but visually ugly code — it adds parentheses around special forms like `defmodule(Foo) do`. This is cosmetically unpleasant but harmless: `Code.format_string!/1` cleans these up automatically. Never use `Macro.to_string/1` output directly as the final result.

### 3.4 Output Module Structure

Generated Elixir code wraps everything in a `defmodule TranslatedCode do ... end` block:

- Python function definitions become `defp` (private functions)
- The module has a single `def run do ... end` public function containing all top-level (non-function) statements
- `import Bitwise` is unconditionally included at the top of the module
- Runtime helper functions are emitted as `defp` inside the module
- The generated code ends with `TranslatedCode.run()` to execute the entry point

---

## §4. Python AST Reference

### 4.1 Input Format

The library consumes a parsed Python AST represented as an Elixir map. The input is a `Module` node (the root of any Python AST) already parsed by Python 3.14's `ast` module and serialized to JSON.

**Python 3.14 AST:** The only literal node is `Constant`. The old `ast.Num`, `ast.Str`, `ast.Bytes`, `ast.NameConstant`, and `ast.Ellipsis` nodes were removed in Python 3.14. The converter does not need to handle these legacy nodes.

**Version-dependent fields are optional.** Use `Map.get(node, "type_params", [])` rather than `node["type_params"]` since `type_params` was added in Python 3.12. Similarly, `Map.get(node, "kind", nil)` for `Constant.kind`.

### 4.2 Metadata Stripping

Location metadata (`lineno`, `col_offset`, `end_lineno`, `end_col_offset`) and type information (`type_comment`) are stripped before JSON serialization. Only structural information is needed.

### 4.3 The `ctx` Field

Most expression nodes include a `ctx` field (`Load`, `Store`, or `Del`). The converter ignores this — context is determined structurally by the parent node.

### 4.4 Supported Node Types

#### Root Nodes
**`Module(body: stmt*)`** — Top-level wrapper.

#### Literals
**`Constant(value: constant, kind: string?)`** — All literal values in Python 3.14. `value` can be `int`, `float`, `str`, `bool`, `None`. After JSON serialization and `Jason.decode!/1`, Python's `True`/`False`/`None` become Elixir's `true`/`false`/`nil`.

Unsupported `Constant` values: complex numbers (`3+4j`), bytes (`b"hello"`), Ellipsis (`...`). These raise `UnsupportedNodeError`.

**Gotcha — complex numbers:** JSON has no native complex type. Serialized form depends on the `ast2json` implementation. Detection heuristic: check if the JSON value is a map/object or if the value type doesn't match any expected type.

#### Variables
**`Name(id: identifier, ctx: expr_context)`** — Variable reference.

**`Starred(value: expr, ctx: expr_context)`** — `*var` unpacking in function call arguments (`fn(*args)`). `Starred` in assignment targets (`a, *b = ...`) is unsupported.

#### Collections
**`List(elts: expr*, ctx: expr_context)`** — List literal.

**`Tuple(elts: expr*, ctx: expr_context)`** — Tuple literal. Also used as assignment target for unpacking.

**`Dict(keys: expr?*, values: expr*)`** — Dictionary literal. Parallel `keys`/`values` lists. When dictionary unpacking is used (`{**d}`), the corresponding `keys` entry is `nil`.

#### Operators (Never Standalone)
Operators are child nodes of `BinOp`, `UnaryOp`, `BoolOp`, and `Compare`. Each has only `"_type"` and no other fields.

**Binary** (used by `BinOp`): `Add`, `Sub`, `Mult`, `Div`, `FloorDiv`, `Mod`, `Pow`, `LShift`, `RShift`, `BitOr`, `BitXor`, `BitAnd`

**Unary** (used by `UnaryOp`): `UAdd`, `USub`, `Not`, `Invert`

**Boolean** (used by `BoolOp`): `And`, `Or`

**Comparison** (used by `Compare`): `Eq`, `NotEq`, `Lt`, `LtE`, `Gt`, `GtE`, `Is`, `IsNot`, `In`, `NotIn`

**IMPORTANT:** `And`/`Or` belong to `BoolOp` (which uses a `values` list), NOT to `BinOp` (which uses `left`/`right`). `In`/`NotIn`/`Is`/`IsNot` belong to `Compare`, NOT to `BinOp`.

**Unsupported operator:** `MatMult` (matrix multiplication) — raises `UnsupportedNodeError`.

#### Expressions

**`BinOp(left: expr, op: operator, right: expr)`** — Binary operation.

**`UnaryOp(op: unaryop, operand: expr)`** — Unary operation.

**`BoolOp(op: boolop, values: expr*)`** — Boolean operation. **CRITICALLY different from `BinOp`**: uses a `values` list, NOT `left`/`right`. Consecutive same-operator operations are collapsed: `a and b and c` → one `BoolOp` with three `values`.

**`Compare(left: expr, ops: cmpop*, comparators: expr*)`** — Comparison. Supports chaining: `a < b < c` has `ops: [Lt, Lt]`, `comparators: [b, c]`.

**`Call(func: expr, args: expr*, keywords: keyword*)`** — Function call. `func` is typically `Name` or `Attribute`.

**`keyword(arg: identifier?, value: expr)`** — Keyword argument. `arg` is `nil` for `**kwargs` unpacking.

**`IfExp(test: expr, body: expr, orelse: expr)`** — Ternary expression. Note: Python syntax is `body if test else orelse`, but AST stores `test` first.

**`Attribute(value: expr, attr: identifier, ctx: expr_context)`** — Attribute access (e.g., `obj.method`).

**`Subscript(value: expr, slice: expr, ctx: expr_context)`** — Subscript access (`x[0]`, `x[1:3]`).

**`Slice(lower: expr?, upper: expr?, step: expr?)`** — Slice object. All fields optional. Appears only inside `Subscript.slice`.

**`Lambda(args: arguments, body: expr)`** — Anonymous function. `body` is a single expression.

**`ListComp(elt: expr, generators: comprehension*)`** — List comprehension.

**`comprehension(target: expr, iter: expr, ifs: expr*, is_async: int)`** — One `for` clause in a comprehension.

#### Statements

**`Assign(targets: expr*, value: expr)`** — Assignment. **`targets` is a list** — `a = b = 5` has `targets: [Name("a"), Name("b")]`. Tuple unpacking is a `Tuple` node inside `targets`.

**`AugAssign(target: expr, op: operator, value: expr)`** — Augmented assignment (`a += 1`). `target` is a single node.

**`Return(value: expr?)`** — Return statement. `value` is optional (bare `return`).

**`Expr(value: expr)`** — Expression used as statement. This is where mutation-method detection happens.

**`If(test: expr, body: stmt*, orelse: stmt*)`** — If statement. `elif` is a nested `If` inside `orelse`.

**`For(target: expr, iter: expr, body: stmt*, orelse: stmt*)`** — For loop. Non-empty `orelse` raises `UnsupportedNodeError`.

**`While(test: expr, body: stmt*, orelse: stmt*)`** — While loop. Non-empty `orelse` raises `UnsupportedNodeError`.

**`Pass`** — No-op statement. **`Break`** — Loop break. **`Continue`** — Loop continue.

**`Assert(test: expr, msg: expr?)`** — Assertion.

**`FunctionDef(name: identifier, args: arguments, body: stmt*, decorator_list: expr*, returns: expr?, type_params: type_param*)`** — Function definition. `type_params` (Python 3.12+) and `returns` are ignored.

**`arguments(posonlyargs: arg*, args: arg*, vararg: arg?, kwonlyargs: arg*, kw_defaults: expr?*, kwarg: arg?, defaults: expr*)`** — Function arguments. `defaults` is a list of default values for the last N `args` parameters.

**`arg(arg: identifier, annotation: expr?)`** — Single argument. `annotation` is ignored.

#### Explicitly Unsupported (raises `UnsupportedNodeError`)

`ClassDef`, `AsyncFunctionDef`, `AsyncFor`, `AsyncWith`, `Import` (except `import math`), `ImportFrom`, `Try`, `TryStar`, `ExceptHandler`, `With`, `Raise`, `Global`, `Nonlocal`, `Yield`, `YieldFrom`, `Await`, `Match`, `match_case`, `Delete`, `AnnAssign`, `TypeAlias`, `GeneratorExp`, `SetComp`, `DictComp`, `FormattedValue`, `JoinedStr`, `TemplateStr`, `Interpolation`, `Set`, `NamedExpr`, `Starred` (in assignment targets), `MatMult`

**`GeneratorExp` interaction with builtins:** `sum(x**2 for x in items)` will crash on the `GeneratorExp` child. Either special-case it (converting to `Enum.sum(Enum.map(...))`) or raise `UnsupportedNodeError` with a clear message.

**`Set` literal vs `set()` constructor:** The `Set` AST node (literal syntax `{1, 2, 3}`) is unsupported. The `set()` constructor (a `Call` to `Name("set")`) IS supported via the builtins table and maps to `MapSet.new(Enum.to_list(x))`.

---

## §5. Elixir AST Reference

### 5.1 The Three-Tuple Rule

Every non-literal expression in Elixir's AST is a three-element tuple:

```elixir
{name_or_operator, metadata, arguments_or_context}
```

Literals that represent themselves (no wrapping): atoms (`:ok`, `true`, `false`, `nil`), integers, floats, strings, lists, and two-element tuples.

### 5.2 Common AST Patterns

```elixir
# Variable
{:my_var, [], nil}

# Local call: sum(1, 2)
{:sum, [], [1, 2]}

# Remote call: Enum.sort(list)
{{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [{:list, [], nil}]}

# Operators: a + b, a && b, !a
{:+, [], [a_ast, b_ast]}
{:&&, [], [a_ast, b_ast]}
{:!, [], [a_ast]}

# String concatenation: a <> b
{:<>, [], [a_ast, b_ast]}

# Multiple statements (block)
{:__block__, [], [stmt1, stmt2]}  # Single statement: no __block__

# if expression
{:if, [], [condition_ast, [do: body_ast, else: else_ast]]}

# cond expression
{:cond, [], [[do: [{:->, [], [[test], body]}, ...]]]}

# def/defp
{:defp, [], [{:name, [], [params]}, [do: body_ast]]}

# Default argument: greeting \\ "Hello"
{:\\, [], [{:greeting, [], nil}, "Hello"]}

# Anonymous function: fn x -> x + 1 end
{:fn, [], [{:->, [], [[{:x, [], nil}], {:+, [], [{:x, [], nil}, 1]}]}]}

# Maps: %{"key" => value}
{:%{}, [], [{"key", value_ast}]}

# 2-element tuple: {a, b}
{a_ast, b_ast}

# 3+ element tuple: {a, b, c}
{:{}, [], [a_ast, b_ast, c_ast]}

# try/catch
{:try, [], [[do: body_ast], [catch: [{:->, [], [[pattern], handler]}]]]}

# Module alias
{:__aliases__, [], [:Enum]}
```

### 5.3 Boolean Operators: Use `&&`/`||`/`!`, NOT `and`/`or`/`not`

Elixir's `and`/`or`/`not` are strict boolean operators — they raise `BadBooleanError` on non-boolean values. The Elixir docs confirm: providing a non-boolean to `and` raises `BadBooleanError`. Python's boolean operators accept any value. Since Python algorithmic code frequently uses truthiness checks on integers and strings (`if my_list:` meaning "if not empty"), the strict operators would crash.

`&&`/`||`/`!` accept any value, matching Python's flexibility (though with Elixir's truthiness model, not Python's — see §6.3).

---

## §6. Edge Cases and Correctness Traps

### 6.1 Integer Floor Division (`//`)

Python's `//` floors toward negative infinity. Elixir's `div/2` truncates toward zero. The Elixir docs confirm: `Integer.floor_div/2` performs floored integer division, rounding toward negative infinity.

| Expression | Python | Elixir `div/2` | Elixir `Integer.floor_div/2` |
|---|---|---|---|
| `-7 // 2` | `-4` | `-3` ✗ | `-4` ✓ |
| `7 // -2` | `-4` | `-3` ✗ | `-4` ✓ |

**Translation:** `FloorDiv` → `Integer.floor_div(a, b)`. Never use `div/2`.

**Limitation — float operands:** Python's `//` works on floats (`7.5 // 2.0` → `3.0`). `Integer.floor_div/2` only accepts integers and raises `ArithmeticError` on floats. Document as known limitation for MVP.

### 6.2 Integer Modulo (`%`)

Python's `%` uses floored modulo. Elixir's `rem/2` uses truncated remainder. The Elixir docs confirm: `Integer.mod/2` uses floored division, with the result always having the sign of the divisor.

| Expression | Python | Elixir `rem/2` | Elixir `Integer.mod/2` |
|---|---|---|---|
| `-7 % 3` | `2` | `-1` ✗ | `2` ✓ |
| `7 % -3` | `-2` | `1` ✗ | `-2` ✓ |

**Translation:** `Mod` → `Integer.mod(a, b)`. Never use `rem/2`.

### 6.3 Truthiness (Critical Semantic Gap)

Python treats many values as falsy (`0`, `0.0`, `""`, `[]`, `{}`, `set()`, `None`, `False`). Elixir only treats `nil` and `false` as falsy. The Elixir docs confirm: "false and nil are considered 'falsy', all other values are considered 'truthy'" and "values like 0 and \"\", which some other programming languages consider to be 'falsy', are also 'truthy' in Elixir."

**This is the single largest semantic gap.**

**Solution:** A `truthy?/1` helper that implements Python's truthiness model. See §9 for the canonical definition.

**Translation rules:**

| Python | Elixir |
|---|---|
| `if x:` | `if truthy?(x) do ... end` |
| `not x` | `!truthy?(x)` |
| `while x:` | `if truthy?(x) do ... end` in recursive helper |

**Optimization:** Conditions that are `Compare` nodes always produce `true`/`false` and can skip `truthy?` wrapping.

**Known limitation for `and`/`or`:** Python's `and`/`or` return operand values (not booleans) and use Python truthiness for short-circuiting. Multiple authoritative sources confirm: Python's `and` returns the first falsy operand or the last operand; `or` returns the first truthy operand or the last operand. Elixir's `&&`/`||` also return operand values but use Elixir truthiness. This means:

| Expression | Python result | Elixir `&&`/`||` result | Match? |
|---|---|---|---|
| `0 and 5` | `0` (0 is falsy) | `5` (0 is truthy) | ✗ |
| `"" or "default"` | `"default"` ("" is falsy) | `""` ("" is truthy) | ✗ |
| `None and 5` | `None` | `nil` | ✓ |
| `1 and 2` | `2` | `2` | ✓ |

For code where `and`/`or` is used purely for boolean logic (the common case), `&&`/`||` works correctly. For code exploiting short-circuit value semantics with `0`, `""`, or `[]`, the translation is wrong. Document as known limitation.

### 6.4 Chained Comparisons

Python chains comparisons: `1 < x < 10` means `1 < x and x < 10`. Elixir has no equivalent — `1 < x < 10` would parse as `(1 < x) < 10`, comparing a boolean to an integer.

**Translation:** Expand to `&&` chain: `1 < x && x < 10`.

### 6.5 `enumerate` Argument Order

Python's `enumerate` yields `(index, element)`. Elixir's `Enum.with_index/1` yields `{element, index}` — the order is swapped. Confirmed by the Elixir Enum typespec: `with_index(t(), integer()) :: [{element(), index()}]`.

**Translation:** Destructure with swapped order in the `fn` parameter: `fn {x, i}, acc -> ...`.

### 6.6 Dictionary Key Access

Python's `d[key]` raises `KeyError` if key is missing. Must use `Map.fetch!/2` (not `Map.get/2`) to match.

| Python | Elixir |
|---|---|
| `d[key]` | `Map.fetch!(d, key)` — raises on missing key |
| `d.get(key)` | `Map.get(d, key)` — nil if missing |
| `d.get(key, 0)` | `Map.get(d, key, 0)` — default if missing |

**NEVER** use `Map.get/2` or Elixir's `d[key]` syntax for Python's `d[key]` — they return `nil` instead of raising.

### 6.7 `print()` String Representation

`to_string/1` does NOT match Python's `str()` for booleans and `None`:

| Value | Python `str()` | Elixir `to_string/1` |
|---|---|---|
| `True` | `"True"` | `"true"` ✗ |
| `False` | `"False"` | `"false"` ✗ |
| `None` | `"None"` | `""` ✗ |
| `[65, 66]` | `"[65, 66]"` | `"AB"` ✗ (charlist) |
| `{1, 2}` | `"(1, 2)"` | raises `Protocol.UndefinedError` ✗ |

**Translation:** Always use `py_str/1` helper instead of `to_string/1`. See §9.

### 6.8 String Concatenation with `+`

Python uses `+` for both arithmetic addition and string concatenation. In Elixir, `+` is arithmetic only — string concatenation uses `<>`. `"hello" + " world"` raises `ArithmeticError`.

**Translation:** All `BinOp` `Add` nodes emit `py_add(a, b)` — a runtime-dispatching helper that handles strings, lists, booleans, and numbers. See §9.

### 6.9 String/List Repetition with `*`

Python uses `*` for string/list repetition: `"abc" * 3`, `[0] * n`. Elixir's `*` is arithmetic only.

**Translation:** All `BinOp` `Mult` nodes where operand types are unknown emit `py_mult(a, b)`. Critical: use `Enum.concat/1` (one-level flatten), NOT `List.flatten/1` (recursive):

```elixir
# Python: [[1, 2]] * 3  →  [[1, 2], [1, 2], [1, 2]]
List.duplicate([[1, 2]], 3) |> Enum.concat()     # [[1, 2], [1, 2], [1, 2]] ✓
List.duplicate([[1, 2]], 3) |> List.flatten()     # [1, 2, 1, 2, 1, 2] ✗ WRONG
```

Negative repeat counts: Python returns `""` or `[]`. Elixir's `String.duplicate/2` and `List.duplicate/2` raise on negative counts. The `py_mult` helper guards against this.

### 6.10 Power Operator (`**`)

`:math.pow/2` always returns a float, so `2 ** 3` returns `8.0` instead of `8`. When both operands are known integers with non-negative exponent, use `Integer.pow/2` to preserve integer type. The `py_pow/2` helper dispatches accordingly. See §9.

**Known limitation — large integer exponents:** `:math.pow(2, 1000)` loses precision (IEEE 754 float). `py_pow` uses `Integer.pow` when both operands are integers with non-negative exponent.

### 6.11 Boolean Values in Arithmetic (Critical)

In Python, `bool` is a subclass of `int` — PEP 285 confirms: "The bool type would be a straightforward subtype (in C) of the int type." `True + True` equals `2`, `False + 1` equals `1`. In Elixir, `true + 1` raises `ArithmeticError`.

The `py_add` and `py_mult` helpers include `is_boolean` clauses that convert booleans to integers before arithmetic. The `is_boolean` clauses must come before `is_number` clauses. Note: `is_integer(true)` returns `false` in Elixir (booleans are atoms, not integers), so there is no guard-ordering conflict.

### 6.12 Boolean Values in Comparisons

In Python, `True > 0.5` → `True` (because `1 > 0.5`). In Elixir, `true > 999999999` → `true` because of term ordering: `number < atom`. The Elixir docs confirm this ordering.

**MVP recommendation:** Document as known limitation. The full fix requires wrapping all comparison operators in a helper, significantly impacting code readability.

### 6.13 `isinstance(True, int)` Returns `True` in Python

Python's `isinstance(True, int)` returns `True` because `bool` is a subclass of `int`. The mapping `isinstance(x, int)` → `is_integer(x)` is wrong for booleans since `is_integer(true)` returns `false`.

**Translation:** `isinstance(x, int)` → `is_integer(x) || is_boolean(x)`. The `type(x) == int` → `is_integer(x)` mapping is correct (Python's `type()` checks exact type, not subclasses).

### 6.14 `round()` Banker's Rounding (Critical Silent Trap)

Python's `round()` uses banker's rounding (round-half-to-even). Elixir's `round/1` uses round-half-away-from-zero. The Elixir docs confirm: "If the number is equidistant to the two nearest integers, rounds away from zero."

| Expression | Python (half-to-even) | Elixir `round/1` (half-away-from-zero) |
|---|---|---|
| `round(0.5)` | `0` | `1` ✗ |
| `round(1.5)` | `2` | `2` ✓ |
| `round(2.5)` | `2` | `3` ✗ |
| `round(-0.5)` | `0` | `-1` ✗ |

**IMPORTANT:** Elixir's `Float.round/2` also has no `:half_even` mode — its docs state "The rounding direction always ties to half up." Banker's rounding must be hand-rolled. See `py_round/1` in §9.

### 6.15 List Out-of-Bounds

Python's `my_list[i]` raises `IndexError` on out-of-bounds. `Enum.at/2` returns `nil`. `List.replace_at/3` silently returns the original list on out-of-bounds. Both are silent wrong results.

**MVP recommendation:** Use `Enum.at/2` and document the difference. A stricter version could use `Enum.fetch!/2` (which raises `Enum.OutOfBoundsError`).

### 6.16 Map Ordering vs Dict Ordering

Python 3.7+ guarantees insertion-order dictionaries. Elixir maps have no guaranteed iteration ordering. The Erlang/OTP 26 Highlights confirm: "The new order is undefined and may change between different invocations of the Erlang VM."

**Document as known limitation.** Code depending on dict iteration order needs an ordered map, beyond MVP scope.

### 6.17 `range()` with Negative Step

Python's `range` always excludes the stop value. Elixir ranges are stop-inclusive. The stop boundary adjustment depends on step direction:

| Python | Elixir |
|---|---|
| `range(n)` | `0..(n - 1)//1` |
| `range(a, b)` | `a..(b - 1)//1` |
| `range(a, b, s)` where `s > 0` | `a..(b - 1)//s` |
| `range(a, b, s)` where `s < 0` | `a..(b + 1)//s` |

**WRONG for negative step:** `range(10, 0, -1)` with `a..(b-1)//s` gives `10..-1//-1` which includes `0` and `-1`. **CORRECT:** `10..1//-1`.

When step is a runtime variable: `if step > 0, do: a..(b - 1)//step, else: a..(b + 1)//step`.

### 6.18 Slicing Translation Table

| Python | Elixir |
|---|---|
| `x[a:b]` | `Enum.slice(x, a..(b-1))` |
| `x[:b]` | `Enum.take(x, b)` |
| `x[a:]` | `Enum.drop(x, a)` |
| `x[:]` | `x` (immutable, no copy needed) |
| `x[::n]` (positive) | `Enum.take_every(x, n)` |
| `x[::-1]` | `Enum.reverse(x)` |
| `x[a:b:n]` | `Enum.slice(x, a..(b-1)) \|> Enum.take_every(n)` |

String slicing uses `String.slice/2`, `String.reverse/1`, etc.

### 6.19 `float('inf')` and `float('nan')`

`Float.parse("inf")` returns `:error` — Elixir does not recognize "inf" as a valid float string. Raise `UnsupportedNodeError` for inf/nan strings. Matches approach for `math.inf`.

### 6.20 `str.split("")` Divergence

Python's `"hello".split("")` raises `ValueError: empty separator`. Elixir's `String.split("hello", "")` returns `["", "h", "e", "l", "l", "o", ""]` (with leading/trailing empties). Document as known limitation.

### 6.21 Closure Capture in Loops

Python closures capture variables by reference. In a loop, closures see the current value of the loop variable, not the value at creation time. Elixir's `fn` captures by value. Document as known limitation — fixing requires mutable reference simulation.

### 6.22 XOR Operator Deprecation

Elixir's `^^^` emits a deprecation warning. Confirmed by `elixir-lang/elixir` issue #11590. **Translation:** Use `Bitwise.bxor(a, b)` instead of `a ^^^ b`.

### 6.23 `str.replace(old, new, count)`

Map `count=1` to `String.replace(s, old, new, global: false)`. For `count > 1`, raise `UnsupportedNodeError`. No-argument form maps directly.

### 6.24 `str.strip(chars)` with Character Set

Python's `strip(chars)` removes a set of characters. Elixir's `String.trim/2` removes a prefix/suffix string. For MVP, raise `UnsupportedNodeError` for multi-character strip argument.

---

## §7. Mutation Strategy

### 7.1 Core Principle

Every Python construct that mutates a variable must be translated to a rebinding.

### 7.2 AugAssign Translation

| Python | Elixir |
|---|---|
| `x += n` | `x = py_add(x, n)` |
| `x -= n` | `x = x - n` |
| `x *= n` | `x = py_mult(x, n)` |
| `x /= n` | `x = x / n` |
| `x //= n` | `x = Integer.floor_div(x, n)` |
| `x %= n` | `x = Integer.mod(x, n)` |
| `x **= n` | `x = py_pow(x, n)` |
| `x <<= n` | `x = x <<< n` |
| `x >>= n` | `x = x >>> n` |
| `x \|= n` | `x = x \|\|\| n` |
| `x ^= n` | `x = Bitwise.bxor(x, n)` |
| `x &= n` | `x = x &&& n` |

### 7.3 AugAssign with Subscript Targets

When `AugAssign.target` is a `Subscript` (e.g., `d[key] += 1`), use runtime-dispatching helpers:

```elixir
# d[key] += 1
d = py_setitem(d, key, py_add(py_getitem(d, key), 1))
```

`py_getitem` uses `Map.fetch!/2` for maps (preserves Python's `KeyError` on missing keys) and `Enum.at/2` for lists.

### 7.4 Mutation Methods (Statement-Level)

When called as statements (wrapped in `Expr` node), mutating methods become reassignments:

| Python | Elixir |
|---|---|
| `my_list.append(x)` | `my_list = my_list ++ [x]` |
| `my_list.extend(items)` | `my_list = my_list ++ items` |
| `my_list.sort()` | `my_list = Enum.sort(my_list)` |
| `my_list.sort(key=f)` | `my_list = Enum.sort_by(my_list, f)` |
| `my_list.sort(reverse=True)` | `my_list = Enum.sort(my_list, :desc)` |
| `my_list.sort(key=f, reverse=True)` | `my_list = Enum.sort_by(my_list, f, :desc)` |
| `my_list.reverse()` | `my_list = Enum.reverse(my_list)` |
| `my_list.pop()` | `my_list = List.delete_at(my_list, -1)` |
| `my_list.pop(i)` | `my_list = List.delete_at(my_list, i)` |
| `my_list.insert(i, x)` | `my_list = List.insert_at(my_list, i, x)` |
| `my_list.remove(x)` | `my_list = List.delete(my_list, x)` |
| `my_list.clear()` | `my_list = []` |
| `my_dict.update(other)` | `my_dict = Map.merge(my_dict, other)` |
| `my_dict.pop(key)` | `my_dict = Map.delete(my_dict, key)` |
| `my_dict.clear()` | `my_dict = %{}` |
| `my_set.add(x)` | `my_set = MapSet.put(my_set, x)` |
| `my_set.discard(x)` | `my_set = MapSet.delete(my_set, x)` |
| `my_set.update(items)` | `my_set = MapSet.union(my_set, MapSet.new(items))` |
| `my_set.clear()` | `my_set = MapSet.new()` |

**Note on `list.remove(x)`:** Python raises `ValueError` if not found. Elixir's `List.delete/2` returns unchanged list. Known minor semantic difference.

**`pop()` in assignment context:** `removed = my_list.pop(2)` needs two statements: `removed = Enum.at(my_list, 2)` then `my_list = List.delete_at(my_list, 2)`.

### 7.5 Dictionary and String Methods (Expression-Level)

| Python | Elixir |
|---|---|
| `d.items()` | `Map.to_list(d)` |
| `d.keys()` | `Map.keys(d)` |
| `d.values()` | `Map.values(d)` |
| `d.get(key)` | `Map.get(d, key)` |
| `d.get(key, default)` | `Map.get(d, key, default)` |
| `s.lower()` | `String.downcase(s)` |
| `s.upper()` | `String.upcase(s)` |
| `s.strip()` | `String.trim(s)` |
| `s.lstrip()` | `String.trim_leading(s)` |
| `s.rstrip()` | `String.trim_trailing(s)` |
| `s.startswith(p)` | `String.starts_with?(s, p)` |
| `s.endswith(p)` | `String.ends_with?(s, p)` |
| `s.split()` | `String.split(s)` |
| `s.split(sep)` | `String.split(s, sep)` |
| `s.split(sep, maxsplit)` | `String.split(s, sep, parts: maxsplit + 1)` |
| `sep.join(items)` | `Enum.join(items, sep)` — args swapped |
| `s.replace(old, new)` | `String.replace(s, old, new)` |
| `s.replace(old, new, 1)` | `String.replace(s, old, new, global: false)` |
| `s.find(sub)` | `py_str_find(s, sub)` |
| `s.count(sub)` | `py_str_count(s, sub)` |
| `s.index(x)` | `py_str_index(s, x)` |
| `s.isdigit()` | `Regex.match?(~r/^\d+$/, s)` |
| `s.isalpha()` | `Regex.match?(~r/^\p{L}+$/u, s)` |
| `s.isalnum()` | `Regex.match?(~r/^[\p{L}\d]+$/u, s)` |
| `s.zfill(width)` | `String.pad_leading(s, width, "0")` |

---

## §8. Builtins Mapping Table

| Python | Elixir |
|---|---|
| `len(x)` | `py_len(x)` |
| `range(n)` | `0..(n-1)//1` |
| `range(a, b)` | `a..(b-1)//1` |
| `range(a, b, s)` | See §6.17 |
| `sorted(x)` | `Enum.sort(x)` |
| `sorted(x, reverse=True)` | `Enum.sort(x, :desc)` |
| `sorted(x, key=f)` | `Enum.sort_by(x, f)` |
| `sorted(x, key=f, reverse=True)` | `Enum.sort_by(x, f, :desc)` |
| `reversed(x)` | `Enum.reverse(x)` |
| `enumerate(x)` | `Enum.with_index(x)` — tuple order swapped! |
| `enumerate(x, start)` | `Enum.with_index(x, start)` |
| `zip(a, b)` | `Enum.zip(a, b)` |
| `zip(a, b, c, ...)` | `Enum.zip([a, b, c, ...])` |
| `map(f, x)` | `Enum.map(x, f)` |
| `filter(f, x)` | `Enum.filter(x, f)` |
| `sum(x)` | `Enum.sum(x)` |
| `min(a, b)` | `min(a, b)` |
| `min(iterable)` | `Enum.min(iterable)` |
| `min(a, b, c, ...)` | `Enum.min([a, b, c, ...])` |
| `max(a, b)` | `max(a, b)` |
| `max(iterable)` | `Enum.max(iterable)` |
| `max(a, b, c, ...)` | `Enum.max([a, b, c, ...])` |
| `abs(x)` | `py_abs(x)` |
| `int()` | `0` |
| `int(x)` | `py_int(x)` |
| `int(x, base)` | `String.to_integer(String.trim(x), base)` |
| `float()` | `0.0` |
| `float(x)` | `py_float(x)` |
| `str(x)` | `py_str(x)` |
| `bool(x)` | `truthy?(x)` |
| `list(x)` | `Enum.to_list(x)` |
| `tuple(x)` | `List.to_tuple(Enum.to_list(x))` |
| `set(x)` | `MapSet.new(Enum.to_list(x))` |
| `dict(x)` | `Map.new(Enum.to_list(x))` |
| `type(x) == int` | `is_integer(x)` |
| `type(x) == float` | `is_float(x)` |
| `type(x) == str` | `is_binary(x)` |
| `type(x) == bool` | `is_boolean(x)` |
| `type(x) == list` | `is_list(x)` |
| `type(x) == dict` | `is_map(x)` |
| `isinstance(x, int)` | `is_integer(x) \|\| is_boolean(x)` |
| `isinstance(x, float)` | `is_float(x)` |
| `isinstance(x, str)` | `is_binary(x)` |
| `isinstance(x, bool)` | `is_boolean(x)` |
| `isinstance(x, list)` | `is_list(x)` |
| `isinstance(x, dict)` | `is_map(x)` |
| `isinstance(x, (int, float))` | `is_number(x)` |
| `print()` | `IO.puts("")` |
| `print(x)` | `IO.puts(py_str(x))` |
| `print(a, b, c)` | `IO.puts(Enum.join([py_str(a), py_str(b), py_str(c)], " "))` |
| `input()` | `py_input("")` |
| `input(prompt)` | `py_input(prompt)` |
| `chr(n)` | `List.to_string([n])` |
| `ord(c)` | `String.to_charlist(c) \|> hd()` |
| `hex(n)` | `py_hex(n)` |
| `oct(n)` | `py_oct(n)` |
| `bin(n)` | `py_bin(n)` |
| `round(x)` | `py_round(x)` |
| `round(x, n)` | `py_round(x, n)` |
| `divmod(a, b)` | `{Integer.floor_div(a, b), Integer.mod(a, b)}` |
| `any(x)` | `Enum.any?(x, &truthy?/1)` |
| `all(x)` | `Enum.all?(x, &truthy?/1)` |
| `math.ceil(x)` | `ceil(x)` |
| `math.floor(x)` | `floor(x)` |
| `math.sqrt(x)` | `:math.sqrt(x)` |
| `math.log(x)` | `:math.log(x)` |
| `math.log2(x)` | `:math.log2(x)` |
| `math.log10(x)` | `:math.log10(x)` |
| `math.gcd(a, b)` | `Integer.gcd(a, b)` |
| `math.gcd(a, b, c, ...)` | `Enum.reduce([a, b, c, ...], &Integer.gcd/2)` |
| `math.pow(x, n)` | `:math.pow(x, n)` |
| `math.pi` | `:math.pi()` |
| `math.e` | `:math.exp(1)` |
| `math.inf` | **RAISES UnsupportedNodeError** |

---

## §9. Runtime Helpers (Canonical Definitions)

All helpers are emitted as `defp` inside the generated `TranslatedCode` module. They are NOT remote calls to `Pylixir.Helpers`.

```elixir
# === Truthiness ===
defp truthy?(nil), do: false
defp truthy?(false), do: false
defp truthy?(0), do: false
defp truthy?(0.0), do: false
defp truthy?(""), do: false
defp truthy?([]), do: false
defp truthy?(%MapSet{} = s), do: MapSet.size(s) > 0
defp truthy?(map) when is_map(map) and map_size(map) == 0, do: false
defp truthy?(_), do: true
# NOTE: %MapSet{} clause MUST appear before is_map clause.
# MapSet is a struct backed by a map, so is_map(MapSet.new()) returns true.
# map_size on a MapSet returns 2 (for __struct__ and map fields), not 0.
# Always use MapSet.size/1 for set emptiness checks.

# === Arithmetic with type dispatch ===
defp py_add(a, b) when is_boolean(a), do: py_add(py_bool_to_int(a), b)
defp py_add(a, b) when is_boolean(b), do: py_add(a, py_bool_to_int(b))
defp py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
defp py_add(a, b) when is_number(a) and is_number(b), do: a + b
defp py_add(a, b) when is_list(a) and is_list(b), do: a ++ b
defp py_add(a, b), do: a + b

defp py_mult(a, b) when is_boolean(a), do: py_mult(py_bool_to_int(a), b)
defp py_mult(a, b) when is_boolean(b), do: py_mult(a, py_bool_to_int(b))
defp py_mult(a, b) when is_binary(a) and is_integer(b) and b > 0, do: String.duplicate(a, b)
defp py_mult(a, b) when is_binary(a) and is_integer(b), do: ""
defp py_mult(a, b) when is_integer(a) and is_binary(b) and a > 0, do: String.duplicate(b, a)
defp py_mult(a, b) when is_integer(a) and is_binary(b), do: ""
defp py_mult(a, b) when is_list(a) and is_integer(b) and b > 0, do: List.duplicate(a, b) |> Enum.concat()
defp py_mult(a, b) when is_list(a) and is_integer(b), do: []
defp py_mult(a, b) when is_integer(a) and is_list(b) and a > 0, do: List.duplicate(b, a) |> Enum.concat()
defp py_mult(a, b) when is_integer(a) and is_list(b), do: []
defp py_mult(a, b), do: a * b

defp py_pow(base, exp) when is_integer(base) and is_integer(exp) and exp >= 0, do: Integer.pow(base, exp)
defp py_pow(base, exp), do: :math.pow(base, exp)

# === Collection access ===
defp py_len(x) when is_list(x), do: length(x)
defp py_len(x) when is_binary(x), do: String.length(x)
defp py_len(%MapSet{} = x), do: MapSet.size(x)
defp py_len(x) when is_map(x), do: map_size(x)
defp py_len(x) when is_tuple(x), do: tuple_size(x)

defp py_getitem(c, k) when is_list(c), do: Enum.at(c, k)
defp py_getitem(c, k) when is_binary(c), do: String.at(c, k)
defp py_getitem(c, k) when is_tuple(c) and k >= 0, do: elem(c, k)
defp py_getitem(c, k) when is_tuple(c), do: elem(c, tuple_size(c) + k)
defp py_getitem(c, k) when is_map(c), do: Map.fetch!(c, k)

defp py_setitem(c, k, v) when is_list(c), do: List.replace_at(c, k, v)
defp py_setitem(c, k, v) when is_map(c), do: Map.put(c, k, v)

defp py_in(x, c) when is_list(c), do: x in c
defp py_in(x, c) when is_binary(c), do: String.contains?(c, x)
defp py_in(x, %MapSet{} = c), do: MapSet.member?(c, x)
defp py_in(x, c) when is_map(c), do: Map.has_key?(c, x)
defp py_in(x, c) when is_tuple(c), do: py_in(x, Tuple.to_list(c))
defp py_in(x, c), do: Enum.member?(c, x)

# === Type conversion ===
defp py_bool_to_int(true), do: 1
defp py_bool_to_int(false), do: 0
defp py_bool_to_int(x), do: x

defp py_int(true), do: 1
defp py_int(false), do: 0
defp py_int(x) when is_float(x), do: trunc(x)
defp py_int(x) when is_integer(x), do: x
defp py_int(x) when is_binary(x), do: String.trim(x) |> String.to_integer()

defp py_float(true), do: 1.0
defp py_float(false), do: 0.0
defp py_float(x) when is_integer(x), do: x / 1
defp py_float(x) when is_float(x), do: x
defp py_float(x) when is_binary(x) do
  trimmed = String.trim(x)
  case String.downcase(trimmed) do
    s when s in ~w[inf +inf -inf infinity +infinity -infinity nan] ->
      raise UnsupportedNodeError, node_type: "float('#{trimmed}')"
    _ ->
      case Float.parse(trimmed) do
        {f, ""} -> f
        _ -> raise ArgumentError, "could not convert string to float: #{inspect(x)}"
      end
  end
end

# === String representation ===
defp py_str(true), do: "True"
defp py_str(false), do: "False"
defp py_str(nil), do: "None"
defp py_str(x) when is_atom(x), do: Atom.to_string(x)
defp py_str(x) when is_list(x), do: py_repr_list(x)
defp py_str(x) when is_tuple(x), do: py_repr_tuple(x)
defp py_str(x) when is_map(x) and not is_struct(x), do: py_repr_map(x)
defp py_str(x), do: to_string(x)

defp py_repr_list(items), do: "[" <> Enum.map_join(items, ", ", &py_repr/1) <> "]"

defp py_repr_tuple(t) do
  items = Tuple.to_list(t)
  case items do
    [single] -> "(" <> py_repr(single) <> ",)"
    _ -> "(" <> Enum.map_join(items, ", ", &py_repr/1) <> ")"
  end
end

defp py_repr_map(m) do
  "{" <> Enum.map_join(m, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end) <> "}"
end

defp py_repr(x) when is_binary(x), do: "'" <> x <> "'"
defp py_repr(x), do: py_str(x)

# === String methods ===
defp py_str_find(s, sub) do
  case String.split(s, sub, parts: 2) do
    [_] -> -1
    [before, _] -> String.length(before)
  end
end

# "abc".count("") returns 4 (len + 1) in Python.
# String.split("aaa", "a") returns ["", "", "", ""] (length 4), so length - 1 = 3.
defp py_str_count(s, ""), do: String.length(s) + 1
defp py_str_count(s, sub), do: length(String.split(s, sub)) - 1

defp py_list_index(list, x) do
  case Enum.find_index(list, fn v -> v == x end) do
    nil -> raise RuntimeError, "#{inspect(x)} is not in list"
    idx -> idx
  end
end

# === Numeric formatting ===
defp py_hex(n) when n < 0, do: "-0x" <> String.downcase(Integer.to_string(-n, 16))
defp py_hex(n), do: "0x" <> String.downcase(Integer.to_string(n, 16))

defp py_oct(n) when n < 0, do: "-0o" <> Integer.to_string(-n, 8)
defp py_oct(n), do: "0o" <> Integer.to_string(n, 8)

defp py_bin(n) when n < 0, do: "-0b" <> Integer.to_string(-n, 2)
defp py_bin(n), do: "0b" <> Integer.to_string(n, 2)

defp py_abs(x) when is_boolean(x), do: py_bool_to_int(x)
defp py_abs(x), do: abs(x)

# === Banker's rounding (Python semantics) ===
# Python round() uses half-to-even. Elixir round/1 uses half-away-from-zero.
# Elixir Float.round/2 also has no :half_even mode, so this must be hand-rolled.
defp py_round(x) when is_integer(x), do: x
defp py_round(x) when is_float(x) do
  truncated = trunc(x)
  diff = x - truncated
  cond do
    abs(diff) < 0.5 -> truncated
    abs(diff) > 0.5 -> if x > 0, do: truncated + 1, else: truncated - 1
    rem(truncated, 2) == 0 -> truncated
    true -> if x > 0, do: truncated + 1, else: truncated - 1
  end
end

defp py_round(x, n) when is_integer(x), do: x
defp py_round(x, n) when is_float(x) do
  multiplier = :math.pow(10, n)
  py_round(x * multiplier) / multiplier
end

# === Input ===
defp py_input(prompt) do
  case IO.gets(prompt) do
    :eof -> raise RuntimeError, "EOFError"
    line -> String.trim_trailing(line, "\n")
  end
end
```

---

## §10. Implementation Notes

### 10.1 Attribute-Node Dispatch (Method Calls and `math` Module)

The `Call` handler must detect `Attribute`-based patterns:

1. `func.value.id == "math"` → math builtins table
2. `attr` in mutation methods AND parent is `Expr` → mutation (§7.4)
3. `attr` in string/dict/list methods → method call (§7.5)
4. `func.id` in builtins table → builtin function (§8)
5. `func.id` in `known_functions` → local function call
6. Unknown → emit as-is, let Elixir compiler catch errors

**`import math` handling:** The `Import` handler silently ignores `import math` (emits no code) since math functions are pre-mapped. All other `Import`/`ImportFrom` nodes raise `UnsupportedNodeError`.

**`sep.join(items)` reversal:** Detect `attr == "join"` and swap arguments: `Enum.join(items_ast, separator_ast)`.

### 10.2 Context Struct

```elixir
defmodule Pylixir.Context do
  @enforce_keys [:scopes]
  defstruct scopes: [],
            while_counter: 0,
            loop_nesting: 0,
            known_functions: MapSet.new()
end
```

- **`scopes`**: Stack of `MapSet`s tracking bound variable names per scope.
- **`while_counter`**: Unique naming for while loop helper functions.
- **`loop_nesting`**: Depth of nested loops (determines return strategy).
- **`known_functions`**: Pre-collected function names for forward references.

### 10.3 Function Name Collection (Two-Pass)

Before converting the module body, collect all top-level function names:

```elixir
def collect_function_names(body) do
  body
  |> Enum.filter(fn node -> node["_type"] == "FunctionDef" end)
  |> Enum.map(fn node -> node["name"] end)
  |> MapSet.new()
end
```

Nested function names are NOT included — they are local bindings, not module-level functions.

### 10.4 For-Loop State Threading with `Enum.reduce`

Python `for` loops frequently mutate outer-scope variables. The converter detects which variables need threading:

1. Snapshot current scope's bound variables as `pre_loop_vars`
2. Walk loop body AST to collect `assigned_vars` and `read_vars`
3. Conservatively include ALL `assigned_vars` in the accumulator (MVP simplification)

**Translation rules:**

- **No mutated externals:** `Enum.each/2` (but see loop variable leaking note)
- **One mutated external:** `Enum.reduce/3` with simple accumulator
- **Multiple:** `Enum.reduce/3` with tuple accumulator, destructure after

**`continue` in for loops:** Return the accumulator unchanged.

**`break` in for loops:** `throw({:break, {all, accumulated, vars}})`, caught by `try/catch`.

**Loop variable leaking:** Python's loop variable persists after the loop. For MVP, conservatively use `Enum.reduce` for ALL loops, including the loop variable in the accumulator.

### 10.5 While Loop Implementation

Each `while` loop becomes a recursive helper function that threads state via arguments and **returns state as a tuple** when the condition becomes false:

```elixir
defp while_0(x) do
  if truthy?(x < 100) do
    x = x * 2
    while_0(x)
  else
    {x}  # return final state
  end
end

# Caller:
{x} = while_0(initial_x)
```

**Read-only variables:** The helper needs ALL outer-scope variables referenced in the body — not just mutated ones. Read-only vars are passed through but not returned in the state tuple.

**With break:** Wrap the caller in `try`/`catch`. Break throws `{:break, {state}}`.

**With continue:** Recurse immediately, skipping remaining body.

### 10.6 Return Inside Loops

When `return` appears inside a `for` or `while` loop, wrap the entire function body in `try`/`catch`:

```elixir
defp find_first(items, target) do
  try do
    Enum.each(items, fn x ->
      if x == target, do: throw({:return, x})
    end)
    nil
  catch
    {:return, result} -> result
  end
end
```

**When NOT needed:** If all `return` statements are in tail position of each branch, `cond` handles it naturally.

### 10.7 If-Elif-Else Chain Conversion

All chains convert to `cond` blocks. Simple `if` with no `else` emits `if`. Conditions wrapped in `truthy?/1` unless they are `Compare` nodes (which always produce booleans).

### 10.8 Nested Function Definitions

Inner `def` becomes anonymous functions (`fn`) since `defp` cannot capture outer variables:

```elixir
# Python: def outer(x):
#             def inner(y): return x + y
#             return inner(5)
defp outer(x) do
  inner = fn y -> py_add(x, y) end
  inner.(5)
end
```

Recursive inner functions use self-referencing pattern: `helper = fn helper_ref, n -> ... helper_ref.(helper_ref, n-1) end`.

### 10.9 Tuple Swap Evaluation Order

Python evaluates the entire right-hand side before assignment. `a, b = b, a` MUST emit `{a, b} = {b, a}`, never sequential assignment.

### 10.10 Comparison Operator Mapping

```elixir
@comparison_ops %{
  "Eq" => :==, "NotEq" => :!=, "Lt" => :<, "LtE" => :<=,
  "Gt" => :>, "GtE" => :>=, "Is" => :==, "IsNot" => :!=,
  "In" => :in, "NotIn" => :not_in  # special: negate the result
}
```

`Is`/`IsNot` → `==`/`!=` (value equality). Safe because `is` in algorithmic code is almost exclusively `x is None`.

### 10.11 Formatter Pipeline

```elixir
def to_source(python_ast) do
  context = %Pylixir.Context{
    scopes: [MapSet.new()],
    known_functions: collect_function_names(python_ast["body"] || [])
  }
  {elixir_ast, _context} = convert(python_ast, context)
  elixir_ast
  |> Macro.to_string()
  |> Code.format_string!()
  |> IO.iodata_to_binary()
end
```

---

## §11. Testing Strategy

### 11.1 Test Categories

1. **Unit Tests:** Per AST node, verify `convert/2` produces correct Elixir AST.
2. **Integration Tests:** Full Python programs → transpile → verify output compiles and runs.
3. **Semantic Correctness Tests:** Per edge case in §6, verify same output as Python.
4. **Error Handling Tests:** Unsupported nodes raise `UnsupportedNodeError`.
5. **Golden Tests:** Python source files → expected Elixir output files.

### 11.2 Test Corpus

1. Fibonacci (recursive/iterative)
2. Binary search
3. Merge sort
4. Stack/Queue (append/pop)
5. Graph BFS/DFS (dict/list mutation)
6. FizzBuzz (for/range, if/elif, print, string concat)
7. Two Sum (dict, enumerate)
8. Palindrome check (string slicing)
9. Factorial (recursion)
10. Prime sieve (list repetition `[True] * n`)
11. Counting sort (list repetition, boolean arithmetic)
12. Matrix sum (nested for loops)

### 11.3 Critical Semantic Tests

```elixir
test "floor division" do
  assert Integer.floor_div(-7, 2) == -4
end

test "modulo" do
  assert Integer.mod(-7, 3) == 2
end

test "banker's rounding" do
  assert py_round(2.5) == 2  # Python: round(2.5) == 2
  assert py_round(3.5) == 4  # Python: round(3.5) == 4
  assert py_round(0.5) == 0  # Python: round(0.5) == 0
end

test "truthiness" do
  assert truthy?(0) == false
  assert truthy?("") == false
  assert truthy?([]) == false
  assert truthy?(%{}) == false
  assert truthy?(MapSet.new()) == false
  assert truthy?(42) == true
end

test "py_str for booleans and None" do
  assert py_str(true) == "True"
  assert py_str(false) == "False"
  assert py_str(nil) == "None"
end

test "boolean arithmetic" do
  assert py_add(true, true) == 2
  assert py_add(false, 1) == 1
  assert py_mult(true, 3) == 3
end

test "isinstance(True, int) should be true" do
  assert is_integer(true) || is_boolean(true) == true
end

test "hex with negatives" do
  assert py_hex(-255) == "-0xff"
  assert py_hex(255) == "0xff"
end

test "range negative step" do
  assert Enum.to_list(10..1//-1) == [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
end

test "py_str_count empty substring" do
  # Python: "abc".count("") == 4
  assert py_str_count("abc", "") == 4
end
```

---

## §12. Development Steps

| Step | Deliverable |
|------|------------|
| 1 | Project setup, `convert/2` skeleton, Context struct |
| 2 | Literals and variables (`Constant`, `Name`) |
| 3 | Arithmetic operators (`BinOp`, `UnaryOp`) with `py_add`, `py_mult` |
| 4 | Boolean operators (`BoolOp`, `Compare`) with chaining, `truthy?/1` |
| 5 | Control flow (`If`→cond, `For`→reduce, `While`→recursive helper, `Break`, `Continue`, `Pass`) |
| 6 | Functions (`FunctionDef`, `Return`→try/throw/catch, `Lambda`) with two-pass names |
| 7 | Collections (`List`, `Tuple`, `Dict`, `ListComp`) and slicing (`Slice`) |
| 8 | Builtins table, dict methods, string methods, `py_len`, `py_in`, `py_int` |
| 9 | Mutation patterns (`AugAssign`, mutation methods) |
| 10 | `Assert`, `Expr` wrapper, nested functions |
| 11 | Edge case testing (§6) |
| 12 | Golden test corpus and regression testing |

---

## §13. Project Structure

```
pylixir/
├── lib/
│   ├── pylixir.ex                  # Main API (to_source/1, transpile/1)
│   └── pylixir/
│       ├── context.ex              # Context struct
│       ├── converter.ex            # Main convert/2 dispatch
│       ├── nodes/
│       │   ├── literals.ex         # Constant, Name, List, Tuple, Dict
│       │   ├── operators.ex        # BinOp, UnaryOp, BoolOp, Compare
│       │   ├── expressions.ex      # Call, IfExp, Subscript, Slice, ListComp, Lambda
│       │   ├── statements.ex       # Assign, AugAssign, Return, If, For, While, etc.
│       │   └── functions.ex        # FunctionDef, arguments, arg
│       ├── builtins.ex             # Built-in function mapping
│       ├── scope.ex                # Scope management
│       ├── helpers.ex              # Runtime helper code generation
│       ├── formatter.ex            # Formatting pipeline
│       └── errors.ex               # UnsupportedNodeError
├── priv/python/
│   └── serialize.py                # Python AST serialization
├── test/
│   ├── pylixir_test.exs
│   ├── nodes/
│   │   ├── literals_test.exs
│   │   ├── operators_test.exs
│   │   ├── expressions_test.exs
│   │   ├── statements_test.exs
│   │   └── functions_test.exs
│   ├── builtins_test.exs
│   ├── edge_cases_test.exs
│   └── fixtures/
│       ├── python/
│       └── elixir/
├── mix.exs
└── README.md
```

---

## §14. Worked Examples

### 14.1 Simple Function

**Python:**
```python
def add(a, b):
    return a + b

print(add(3, 4))
```

**Elixir:**
```elixir
defmodule TranslatedCode do
  import Bitwise

  # ... helpers ...

  defp add(a, b), do: py_add(a, b)

  def run do
    IO.puts(py_str(add(3, 4)))
  end
end

TranslatedCode.run()
```

### 14.2 While Loop with Break/Continue

**Python:**
```python
count = 0
while count < 5:
    count += 1
    if count == 3:
        continue
    if count == 5:
        break
    print(count)
```

**Elixir:**
```elixir
defmodule TranslatedCode do
  import Bitwise
  # ... helpers ...

  defp while_0(count) do
    if count < 5 do
      count = count + 1
      if count == 3 do
        while_0(count)
      else
        if count == 5 do
          throw({:break, {count}})
        else
          IO.puts(py_str(count))
          while_0(count)
        end
      end
    else
      {count}
    end
  end

  def run do
    count = 0
    {count} = try do
      while_0(count)
    catch
      {:break, state} -> state
    end
    count
  end
end

TranslatedCode.run()
```

### 14.3 Binary Search

**Python:**
```python
def binary_search(arr, target):
    left = 0
    right = len(arr) - 1
    while left <= right:
        mid = (left + right) // 2
        if arr[mid] == target:
            return mid
        elif arr[mid] < target:
            left = mid + 1
        else:
            right = mid - 1
    return -1

result = binary_search([1, 3, 5, 7, 9, 11, 13], 7)
print(result)
```

**Elixir:**
```elixir
defmodule TranslatedCode do
  import Bitwise
  # ... helpers ...

  defp binary_search(arr, target) do
    try do
      left = 0
      right = py_len(arr) - 1
      {left, right} = while_0(arr, target, left, right)
      throw({:return, -1})
    catch
      {:return, result} -> result
    end
  end

  defp while_0(arr, target, left, right) do
    if left <= right do
      mid = Integer.floor_div(py_add(left, right), 2)
      cond do
        py_getitem(arr, mid) == target ->
          throw({:return, mid})
        py_getitem(arr, mid) < target ->
          while_0(arr, target, mid + 1, right)
        true ->
          while_0(arr, target, left, mid - 1)
      end
    else
      {left, right}
    end
  end

  def run do
    result = binary_search([1, 3, 5, 7, 9, 11, 13], 7)
    IO.puts(py_str(result))
  end
end

TranslatedCode.run()
```

Output: `3`

---

## §15. Known Limitations

These are documented semantic differences that the transpiler does NOT attempt to fix:

| # | Severity | Limitation | Section |
|---|----------|-----------|---------|
| 1 | 🔴 | `and`/`or` short-circuit value semantics differ when operands are `0`, `""`, `[]` | §6.3 |
| 2 | 🔴 | Boolean comparison with numbers (`true > 2` wrong in Elixir) | §6.12 |
| 3 | 🔴 | Map iteration order not guaranteed (Python dicts preserve insertion order) | §6.16 |
| 4 | 🔴 | Closure capture in loops (value vs reference) | §6.21 |
| 5 | 🔴 | `List.replace_at/3` silent no-op on out-of-bounds (Python raises `IndexError`) | §6.15 |
| 6 | 🔴 | `Enum.at/2` returns `nil` on out-of-bounds (Python raises `IndexError`) | §6.15 |
| 7 | 🟡 | `list.remove(x)` returns unchanged list instead of raising `ValueError` | §7.4 |
| 8 | 🟡 | Float operands in `//` and `%` raise `ArithmeticError` | §6.1 |
| 9 | 🟡 | `str.split("")` produces different result (Python raises `ValueError`) | §6.20 |
| 10 | 🟡 | `strip(chars)` with multi-character argument unsupported | §6.24 |
| 11 | 🟢 | Unicode grapheme cluster counting may differ from Python codepoint counting | §10 |

**Severity key:** 🔴 = silent wrong result, 🟡 = runtime crash or behavior difference, 🟢 = minor/cosmetic.

---

## §16. Quick Reference Card

| # | Trap | Wrong | Right |
|---|------|-------|-------|
| 1 | Floor division | `div(a, b)` | `Integer.floor_div(a, b)` |
| 2 | Modulo | `rem(a, b)` | `Integer.mod(a, b)` |
| 3 | Truthiness | `if x do` | `if truthy?(x) do` |
| 4 | Chained comparison | `a < b < c` | `a < b && b < c` |
| 5 | Boolean operators | `a and b` | `a && b` |
| 6 | `enumerate` order | `{i, x}` | `{x, i}` |
| 7 | `not`/`!` gap | `!0` → `false` | `!truthy?(0)` → `true` |
| 8 | `d[key]` missing | `Map.get(d, key)` | `Map.fetch!(d, key)` |
| 9 | String concat | `"a" + "b"` | `py_add("a", "b")` |
| 10 | String/list repeat | `"abc" * 3` | `py_mult("abc", 3)` |
| 11 | `print(True)` | `to_string(true)` → `"true"` | `py_str(true)` → `"True"` |
| 12 | `print(None)` | `to_string(nil)` → `""` | `py_str(nil)` → `"None"` |
| 13 | `range` neg step | `a..(b-1)//s` | `a..(b+1)//s` when `s < 0` |
| 14 | Power with floats | `Integer.pow(a, b)` | `py_pow(a, b)` |
| 15 | Boolean arithmetic | `true + 1` crashes | `py_bool_to_int(true) + 1` |
| 16 | `round()` mode | `round(2.5)` → `3` | `py_round(2.5)` → `2` |
| 17 | XOR operator | `a ^^^ b` (deprecated) | `Bitwise.bxor(a, b)` |
| 18 | `isinstance(x, int)` | `is_integer(x)` | `is_integer(x) \|\| is_boolean(x)` |
| 19 | `hex(-255)` | `"0x-ff"` | `"-0xff"` |
| 20 | `return` in loop | direct return | `try`/`throw`/`catch` |
| 21 | While state lost | helper returns `nil` | helper returns `{state}` tuple |
| 22 | Tuple swap | `a = b; b = a` | `{a, b} = {b, a}` |
| 23 | `any()`/`all()` | `Enum.any?([0])` → `true` | `Enum.any?([0], &truthy?/1)` → `false` |
| 24 | iodata gotcha | `Code.format_string!` returns string | Returns iodata; use `IO.iodata_to_binary/1` |
| 25 | `pop()` in assign | only deletes | emit value extraction AND deletion |
| 26 | MapSet vs is_map | `is_map` catches MapSet | `%MapSet{}` clause before `is_map` |
| 27 | `py_str` compounds | `to_string([65])` → `"A"` | `py_repr_list` → `"[65]"` |
| 28 | For-loop var leak | `Enum.each` loses var | Always `Enum.reduce` (MVP) |

---

*End of RFC-001 v10*

*Generated: May 12, 2026*
*Targets: Python 3.14, Elixir 1.19, OTP 26+*
*All claims verified against official documentation (hexdocs.pm, docs.python.org, peps.python.org, elixir-lang/elixir source)*
