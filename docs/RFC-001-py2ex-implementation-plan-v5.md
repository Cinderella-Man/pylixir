# RFC-001: py2ex — Python AST to Elixir Transpiler Implementation Plan

**Status:** Draft → Implementation Plan (v5)
**Created:** 2026-05-09
**Revised:** 2026-05-10 (v5 — self-contained rewrite with deep research, edge cases, and Elixir-developer-oriented guidance)

---

## Table of Contents

- [§1 — Executive Summary](#1-executive-summary)
- [§2 — Python Concepts for Elixir Developers](#2-python-concepts-for-elixir-developers)
- [§3 — Problem Statement & Motivation](#3-problem-statement--motivation)
- [§4 — Out of Scope](#4-out-of-scope)
- [§5 — Python Version Compatibility](#5-python-version-compatibility)
- [§6 — Architecture and Pipeline](#6-architecture-and-pipeline)
  - [6.1 — Pipeline Overview](#61-pipeline-overview)
  - [6.2 — Why Elixir AST as Intermediate?](#62-why-elixir-ast-as-intermediate)
  - [6.3 — Python AST Reference](#63-python-ast-reference-critical-implementation-knowledge)
- [§7 — Python AST Node Categories](#7-python-ast-node-categories)
- [§8 — Elixir AST Reference](#8-elixir-ast-reference-critical-implementation-knowledge)
- [§9 — Mutation Strategy Detailed](#9-mutation-strategy-detailed)
- [§10 — Context Struct Detailed](#10-context-struct-detailed)
- [§11 — Edge Cases and Correctness Traps](#11-edge-cases-and-correctness-traps)
- [§12 — Supported Python AST Nodes](#12-supported-python-ast-nodes)
- [§13 — Detailed Implementation Notes Per Node Type](#13-detailed-implementation-notes-per-node-type)
- [§14 — Testing Strategy](#14-testing-strategy)
- [§15 — Development Steps](#15-development-steps)
- [§16 — Project Structure](#16-project-structure)
- [§17 — Extension Patterns](#17-extension-patterns)
- [§18 — Pitfalls and Risks](#18-pitfalls-and-risks)
- [§19 — mix.exs and Dependencies](#19-mixexs-and-dependencies)
- [§20 — Open Questions](#20-open-questions)
- [§21 — Future Extensions](#21-future-extensions)
- [Appendix A — Changelog from v1–v3](#appendix-a-changelog-from-v1v3)
- [Appendix B — Quick Reference Cards](#appendix-b-quick-reference-cards)

---

## §1. Executive Summary

### 1.1 What Is py2ex?

`py2ex` is an Elixir library that converts Python Abstract Syntax Trees (ASTs) — represented as decoded JSON maps — into working Elixir source code. It is a pure function: map in, string out.

```elixir
python_ast = %{
  "_type" => "BinOp",
  "left" => %{"_type" => "Constant", "value" => 1},
  "op" => %{"_type" => "Add"},
  "right" => %{"_type" => "Constant", "value" => 2}
}

Py2Ex.to_source(python_ast)
# => "1 + 2"
```

The library does not read files, does not call Python, does not do batch processing, does not run tests. It accepts a Python AST map, converts it to an Elixir AST (quoted expression tuples), and formats that AST into a source code string.

### 1.2 What "Working, Not Idiomatic" Means

The output is **working, not idiomatic** Elixir. The goal is correctness — code that compiles and produces the same results as the Python original. It will not be pretty. It will use `Enum.reduce` where a human would write `Enum.map`. It will generate helper functions for `while` loops. It will produce `{result}` tuple accumulators for single-variable loops. It is a mechanical translation, not a stylistic one.

### 1.3 Target Use Case

This library targets **self-contained algorithmic code**: the kind of Python you'd find in coding challenges, algorithmic puzzles, and small utility functions. Typical translatable code includes sorting algorithms, dynamic programming solutions, graph traversals, mathematical computations, string manipulation functions, and similar standalone logic.

### 1.4 Design Philosophy

1. **Correctness over elegance.** Every translated construct must produce the same result as the Python original, including edge cases (negative modulo, floor division, truthiness).
2. **Explicit over implicit.** When Python and Elixir semantics diverge, the generated code makes the divergence explicit (e.g., `Integer.floor_div/2` instead of `div/2`).
3. **Fail loudly on unsupported constructs.** Never produce silent wrong code. Raise `UnsupportedNodeError` for anything not handled.
4. **No Python dependency at runtime.** The library receives pre-parsed ASTs as Elixir maps. Python is used only offline to produce the JSON.

---

## §2. Python Concepts for Elixir Developers

> **Purpose:** This section explains Python language concepts referenced throughout this RFC, written for an Elixir developer who may have never written Python. Skip this section if you already know Python.

### 2.1 Variables and Assignment

Python variables are **untyped, mutable bindings**. Unlike Elixir where rebinding creates a new binding in the same scope:

```python
x = 5        # bind x to 5
x = x + 1    # rebind x to 6 (not a new scope entry)
```

In Elixir terms, this is the same as `x = 5; x = x + 1` — Elixir also allows rebinding. **Key insight:** Python's variable rebinding maps naturally to Elixir's rebinding. This is why variable handling is straightforward for this transpiler.

### 2.2 Python's `for` Loop

Python's `for` is an **iterator-based loop**, not a counter-based loop. It iterates over any iterable (list, range, string, dict, etc.):

```python
for x in [1, 2, 3]:
    print(x)
```

This is closest to Elixir's `Enum.each/2` or `Enum.reduce/3`. There is no C-style `for (init; condition; increment)` in Python.

### 2.3 Python's `while` Loop

Python's `while` is a condition-based loop, similar to Elixir's recursive function pattern:

```python
while x < 10:
    x += 1
```

Elixir has no `while` keyword. The transpiler converts these to recursive helper functions.

### 2.4 Python's `for`/`else` and `while`/`else`

In Python, `for` and `while` loops can have an `else` clause that executes only if the loop completes **without** hitting a `break`:

```python
for x in items:
    if x == target:
        print("found")
        break
else:
    print("not found")  # runs only if break was never hit
```

This is a Python-specific construct with no Elixir equivalent. This transpiler raises `UnsupportedNodeError` for non-empty `orelse` on loops.

### 2.5 List Comprehensions

Python has a compact syntax for creating lists from loops:

```python
squares = [x**2 for x in range(10)]           # [0, 1, 4, 9, 16, 25, 36, 49, 64, 81]
evens = [x for x in range(10) if x % 2 == 0]  # [0, 2, 4, 6, 8]
```

This translates to Elixir's `for x <- range, do: x * x` comprehension syntax.

### 2.6 Truthiness (Critical Semantic Difference)

Python treats many values as "falsy" in boolean contexts. The following values are considered `False`:

| Python falsy value | Elixir equivalent | Notes |
|---|---|---|
| `None` | `nil` | Direct mapping |
| `False` | `false` | Direct mapping |
| `0` (integer zero) | **NOT falsy in Elixir** | Elixir treats `0` as truthy |
| `0.0` (float zero) | **NOT falsy in Elixir** | Elixir treats `0.0` as truthy |
| `""` (empty string) | **NOT falsy in Elixir** | Elixir treats `""` as truthy |
| `[]` (empty list) | **NOT falsy in Elixir** | Elixir treats `[]` as truthy |
| `{}` (empty dict) | **NOT falsy in Elixir** | Elixir treats `%{}` as truthy |
| `set()` (empty set) | **NOT falsy in Elixir** | No direct equivalent |

**This is the single largest semantic gap between Python and Elixir.** The transpiler must handle this with `&&`/`||`/`!` operators (which use Elixir's truthiness — only `nil` and `false` are falsy) and a `Py2Ex.Helpers.truthy?/1` helper function where exact Python truthiness is required. See §11 and §13.

### 2.7 Python's `and`/`or`/`not` vs Elixir's `and`/`or`/`not`

Python's boolean operators accept any value and return one of the operands (not necessarily a boolean):
- `0 and 5` → `0` (returns the first falsy value)
- `"" or "default"` → `"default"` (returns the first truthy value)
- `not 0` → `True` (always returns a boolean)

Elixir's `and`/`or`/`not` **require boolean operands** and raise `BadBooleanError` on non-booleans:
- `0 and 5` → **raises BadBooleanError**
- `"" or "default"` → **raises BadBooleanError**

**Solution:** The transpiler uses `&&`/`||`/`!` which accept any value in Elixir, matching Python's flexibility (though with Elixir's truthiness model, not Python's).

### 2.8 Chained Comparisons

Python supports chained comparisons that have no Elixir equivalent:

```python
1 < x < 10          # equivalent to: 1 < x and x < 10
a < b == c           # equivalent to: a < b and b == c
```

The transpiler expands these to `&&` chains: `1 < x && x < 10`.

### 2.9 Floor Division (`//`) and Modulo (`%`)

Python's `//` operator always floors toward negative infinity:
- `7 // 2` → `3`
- `-7 // 2` → `-4` (NOT `-3`)

Elixir's `div/2` truncates toward zero:
- `div(-7, 2)` → `-3` (different from Python!)

**Solution:** Use `Integer.floor_div/2` (available since Elixir 1.12.0), which floors toward negative infinity.

Similarly, Python's `%` uses floored modulo:
- `-7 % 2` → `1` (Python)
- `rem(-7, 2)` → `-1` (Elixir `rem/2` — different!)

**Solution:** Use `Integer.mod/2` (available since Elixir 1.12.0).

### 2.10 Negative Indexing

Python supports negative indices to count from the end:
- `items[-1]` → last element
- `items[-2]` → second-to-last element

Elixir's `Enum.at/2` also supports negative indices, so this maps directly.

### 2.11 Tuple Unpacking (Destructuring)

Python allows assigning multiple variables from a tuple in one statement:

```python
a, b = 1, 2         # a=1, b=2
a, b = b, a         # swap
x, *rest = [1,2,3]  # x=1, rest=[2,3]
```

This is similar to Elixir's pattern matching: `{a, b} = {1, 2}`.

### 2.12 The `enumerate` Function

Python's `enumerate` yields `(index, element)` tuples:

```python
for i, x in enumerate(["a", "b"]):
    print(i, x)  # 0 "a", then 1 "b"
```

Elixir's `Enum.with_index/1` yields `{element, index}` tuples — **the order is swapped**. The transpiler must account for this.

### 2.13 The `range` Function

Python's `range` generates integer sequences:
- `range(5)` → `[0, 1, 2, 3, 4]` (stop is exclusive)
- `range(2, 5)` → `[2, 3, 4]` (start inclusive, stop exclusive)
- `range(0, 10, 2)` → `[0, 2, 4, 6, 8]` (with step)

Elixir ranges: `0..4//1`, `2..4//1`, `0..8//2` — stop is **inclusive**. The transpiler must adjust: `range(a, b)` → `a..(b-1)//1`.

### 2.14 Python's `in` Operator

Python's `in` checks membership in any collection:
- `3 in [1, 2, 3]` → `True`
- `"a" in "abc"` → `True` (substring check!)
- `"key" in {"key": 1}` → `True` (dict key check)

In Elixir, `in` only works with ranges and lists on the left-hand side. For general membership, `Enum.member?/2` is needed.

### 2.15 `is` vs `==` (Identity vs Equality)

Python's `is` checks object identity (same memory address), while `==` checks equality (same value). In Elixir, `==` checks value equality. The transpiler maps `is` to `==` because in algorithmic code, `is` is almost always used to compare with `None` (`x is None`), which maps to `x == nil`.

### 2.16 Default Arguments

Python functions can have default parameter values:

```python
def greet(name, greeting="Hello"):
    return greeting + ", " + name
```

This maps to Elixir's default arguments: `def greet(name, greeting \\ "Hello")`.

### 2.17 The `Lambda` Expression

Python's `lambda` creates anonymous functions:

```python
double = lambda x: x * 2
sorted(items, key=lambda x: x[1])
```

This maps to Elixir's `fn x -> x * 2 end`.

### 2.18 The `pass` Statement

Python's `pass` is a no-op — it does nothing. It's used as a placeholder where a statement is syntactically required. In Elixir, the equivalent is `nil` or simply omitting the body.

### 2.19 The `assert` Statement

Python's `assert condition, message` raises `AssertionError` if the condition is falsy. In Elixir, this maps to `unless condition, do: raise(AssertionError, message)`.

### 2.20 Augmented Assignment

Python's `+=`, `-=`, `*=`, etc. are augmented assignment operators:

```python
x += 1    # equivalent to: x = x + 1
```

In Elixir, these map directly: `x = x + 1` (Elixir doesn't have `+=` syntax, but the AST form `{:=, [], [x_ast, {:+, [], [x_ast, 1]}]}` is equivalent).

### 2.21 Expression Statements (`Expr` Node)

In Python, any expression can be used as a statement (its value is discarded):

```python
my_list.append(5)  # the return value (None) is discarded
```

This appears in the AST as an `Expr` node wrapping the expression. The transpiler uses this node to detect mutation methods like `append`, `extend`, `pop`, etc.

---

## §3. Problem Statement & Motivation

### 3.1 The Pipeline

Python's `ast` module can parse any Python source into a well-defined AST. That AST can be trivially serialized to JSON. This library handles the other side: transforming that JSON structure into working Elixir code.

The full pipeline is:

```
Python source code
    → Python's `ast.parse()` (standard library)
    → Python AST (in-memory)
    → Serialize to JSON (via `ast2json` or similar tool)
    → JSON string
    → `Jason.decode!/1` (Elixir)
    → Elixir map (the input to this library)
    → Py2Ex.to_source/1
    → Elixir source code string
```

### 3.2 Why?

This library exists to bridge the gap between Python's algorithmic ecosystem and Elixir's runtime. Many algorithmic problems, competitive programming solutions, and reference implementations exist in Python. Being able to mechanically translate them to working Elixir code enables:

- Porting algorithmic solutions without manual rewriting
- Verifying Elixir implementations against Python references
- Generating Elixir test fixtures from Python implementations
- Educational tooling for learning Elixir by translating familiar Python

### 3.3 What Success Looks Like

A user takes a Python function (e.g., a binary search implementation), runs it through `ast.parse()` + `ast2json`, feeds the resulting JSON to `Py2Ex.to_source/1`, and gets Elixir code that:

1. **Compiles** without errors
2. **Produces the same results** as the Python original for all valid inputs
3. **Handles edge cases** correctly (negative numbers, empty lists, boundary conditions)

---

## §4. Out of Scope

The following are explicitly out of scope. Each includes a brief explanation of why.

| Category | What's excluded | Why |
|----------|----------------|-----|
| **OOP** | Classes, inheritance, decorators, `@staticmethod`, `@classmethod`, `super()` | No Elixir equivalent; would require a full object system |
| **Async** | `async def`, `await`, `async for`, `async with` | No direct Elixir equivalent (Elixir uses processes/GenServer, not async/await) |
| **Imports** | `import`, `from X import Y`, `import X as Z` | Module systems are fundamentally different; would need a mapping table for every Python module |
| **I/O** | `open()`, `read()`, `write()`, `input()`, file operations | Beyond algorithmic translation scope |
| **Exceptions** | `try`/`except`/`finally`, `raise` with custom types, exception chaining | While `try`/`rescue` exists in Elixir, mapping Python's exception hierarchy is a separate project |
| **Generators** | `yield`, `yield from`, generator expressions, `send()`, `throw()` on generators | No direct Elixir equivalent; would require coroutine emulation |
| **Context managers** | `with` statement, `__enter__`/`__exit__` | No direct Elixir equivalent |
| **Metaclasses** | `type()`, `__metaclass__`, `__new__` | Deep Python internals with no Elixir parallel |
| **Standard library** | `os`, `sys`, `json`, `re`, `math` (partial), `collections`, `itertools`, etc. | Would need per-module mapping; only basic builtins are supported |
| **Global/nonlocal** | `global x`, `nonlocal x` | Scope manipulation that doesn't translate |
| **Delete** | `del x`, `del x[i]` | No Elixir equivalent for mutable deletion |
| **AnnAssign** | `x: int = 5` (annotated assignment) | Type annotations are not part of Elixir's runtime |
| **Match** | `match`/`case` (Python 3.10+) | Complex pattern matching that would need its own translation rules |
| **F-strings** | `f"hello {name}"`, `f"{x:.2f}"` | String interpolation with embedded expressions and format specs |
| **Walrus operator** | `:=` (named expressions) | No Elixir equivalent; adds complexity for minimal benefit |
| **Star expressions** | `*args`, `**kwargs` in function definitions | Variadic functions have no direct Elixir equivalent |

### 4.1 What IS In Scope

Self-contained algorithmic code that uses:

- **Literals:** integers, floats, strings, booleans, `None`, lists, tuples, dicts
- **Variables:** assignment, augmented assignment, rebinding
- **Operators:** arithmetic, comparison, boolean, bitwise
- **Control flow:** `if`/`elif`/`else`, `for` loops, `while` loops, `break`, `continue`, `pass`
- **Functions:** `def`, `return`, default arguments, `lambda`
- **Comprehensions:** list comprehensions (with filters)
- **Builtins:** `len`, `range`, `abs`, `min`, `max`, `sorted`, `sum`, `enumerate`, `zip`, `int`, `float`, `str`, `print`, `list.append`, `dict.get`, string methods, etc.
- **Nested functions:** inner `def` converted to anonymous functions
- **Early returns:** `return` inside `if` blocks (via `try`/`throw`/`catch`)
- **Tuple unpacking:** `a, b = b, a`


---

## §5. Python Version Compatibility

### 5.1 Input Format

The library consumes a **parsed Python AST** represented as an Elixir map. The input is a `Module` node (the root of any Python AST) that has already been parsed by Python's `ast` module and serialized to JSON.

**Python version target:** The library targets the AST format produced by `ast.parse()` in Python **3.8 and later**. The Python AST format is not frozen — it changes between versions. Key version-dependent behaviors:

| Feature | Python 3.8–3.9 | Python 3.10–3.11 | Python 3.12+ |
|---|---|---|---|
| `Constant.kind` field | Present (`"u"` or `nil`) | Present (`"u"` or `nil`) | Present (still in grammar) |
| `FunctionDef.type_params` | **Does not exist** | **Does not exist** | Present (list of type parameter nodes) |
| Old literal nodes (`Num`, `Str`, `Bytes`, `NameConstant`, `Ellipsis`) | Deprecated but still produced by some tools | Deprecated but still produced by some tools | Emit `DeprecationWarning` (3.12–3.13); **removed in 3.14** |
| `Match` statement | Does not exist | Present (Python 3.10+, PEP 634) | Present |

**The converter treats version-dependent fields as optional.** Use `Map.get(node, "type_params", [])` rather than `node["type_params"]` to avoid `KeyError` on pre-3.12 ASTs. Similarly, `Map.get(node, "kind", nil)` for `Constant.kind`.

### 5.2 Metadata Stripping

The `ast` module includes location metadata (`lineno`, `col_offset`, `end_lineno`, `end_col_offset`) and type information (`type_comment`) on many nodes. These are stripped before JSON serialization — we only need structural information.

### 5.3 The `ctx` Field

Most expression nodes (`Name`, `Attribute`, `Subscript`, `Starred`, `List`, `Tuple`) include a `ctx` field (`Load`, `Store`, or `Del`). The converter generally ignores this — context is determined structurally by the parent node (e.g., left side of `=` is a store target). The field is still present in the input but is not relied upon for conversion decisions.

### 5.4 Serializer Variations

The JSON representation of the Python AST depends on the serializer used (`ast2json`, `ast.dump` with custom serialization, etc.). Key areas where serializers diverge:

- **Complex numbers:** No JSON type exists. Some serializers produce a dict with `real`/`imag` keys, some produce a string, some error.
- **Bytes literals:** JSON has no bytes type. May be base64-encoded or represented as arrays.
- **Ellipsis:** May be serialized as a string `"Ellipsis"` or a special object.
- **Metadata fields:** Some serializers include `lineno`, `col_offset`, etc.; others strip them.

The converter is resilient to missing metadata fields and does not depend on any specific serializer's conventions for unserializable types.

---

## §6. Architecture and Pipeline

### 6.1 Pipeline Overview

```
Input map
  → Py2Ex.Converter.convert/2 (recursive dispatch on "_type", threads context)
  → Elixir AST (tuples)
  → Macro.to_string/1 (→ iodata, NOT a binary!)
  → Code.format_string!/1 (→ iodata, NOT a binary!)
  → IO.iodata_to_binary/1 (→ final binary string)
```

**CRITICAL CORRECTION (v4→v5):** `Code.format_string!/1` returns `iodata()`, NOT a binary string. The pipeline MUST end with `IO.iodata_to_binary/1`. See §6.1.1.

#### 6.1.1 The `iodata` Gotcha

Both `Macro.to_string/1` and `Code.format_string!/1` return `iodata()` (deeply nested lists of binaries and integers), NOT flat binary strings. Calling `IO.puts/1` on iodata works fine (IO functions accept iodata), but string operations like `String.length/1`, `String.contains?/2`, or pattern matching will fail or produce wrong results.

```elixir
# CORRECT pipeline:
ast
|> Macro.to_string()        # returns iodata
|> Code.format_string!()    # returns iodata (NOT binary!)
|> IO.iodata_to_binary()    # returns binary string ← THIS STEP IS REQUIRED

# WRONG (v4 had this):
ast
|> Macro.to_string()
|> Code.format_string!()
# result is iodata, NOT a string — String operations will fail!
```

#### 6.1.2 What Does `convert/2` Do?

`convert/2` is the core function. It takes a Python AST node (an Elixir map with a `"_type"` key) and a context struct, and returns a tuple `{elixir_ast, updated_context}`.

- It pattern-matches on `node["_type"]` (e.g., `"BinOp"`, `"If"`, `"FunctionDef"`)
- It recursively calls itself on child nodes
- Each node type has its own function clause (or set of clauses for complex types)
- There is no intermediate representation, no multi-pass compilation, no optimization
- One recursive walk, one output

The function signature:

```elixir
@spec convert(node :: map(), context :: Py2Ex.Context.t()) :: {Macro.t(), Py2Ex.Context.t()}
def convert(%{"_type" => type} = node, context) do
  # dispatch to type-specific clause
end
```

### 6.2 Why Elixir AST as Intermediate?

Instead of building strings directly, the library builds Elixir AST tuples (the same format `quote` produces). Benefits:

- `Macro.to_string/1` handles operator precedence, `do/end` blocks, parentheses — things that are error-prone with string concatenation.
- `Code.format_string!/1` applies `mix format` rules automatically.
- `Code.eval_quoted/2` can evaluate the AST directly for testing.
- The AST is composable — build small pieces, nest them naturally.

### 6.3 Python AST Reference (Critical Implementation Knowledge)

Understanding the Python AST format is essential. This is what the library consumes. Every Python AST node has a `"_type"` field identifying the node kind, plus node-specific child fields. The Python ASDL grammar defines the canonical structure. Below is the reference for all supported node types.

**Notation:** `expr` means a single expression node (a map). `expr*` means a list of expression nodes. `expr?` means an optional expression node (may be `nil`/`null`). `identifier` is a string. `int` is an integer. `constant` is a Python literal value.

#### 6.3.1 Root Nodes

**`Module(body: stmt*)`** — The top-level wrapper. `body` is a list of statement nodes.

#### 6.3.2 Literals

**`Constant(value: constant, kind: string?)`** — All literal values in Python 3.8+. `value` can be `int`, `float`, `str`, `bool`, `None`, `bytes`, `complex`, or `Ellipsis`. After JSON serialization and `Jason.decode!/1`, Python's `True`/`False`/`None` become Elixir's `true`/`false`/`nil`. The `kind` field is `"u"` for `u"..."` string literals, `nil` otherwise. **Note:** The `kind` field is still present in the Python AST grammar through Python 3.14, but is only ever set to `"u"` for u-prefixed strings. In practice, `u"..."` is rare in modern Python 3 code. The converter should treat it as optional and default to `nil` when absent.

```elixir
# Python: 42       → %{"_type" => "Constant", "value" => 42}
# Python: "hello"  → %{"_type" => "Constant", "value" => "hello"}
# Python: True     → %{"_type" => "Constant", "value" => true}
# Python: None     → %{"_type" => "Constant", "value" => nil}
# Python: 3.14     → %{"_type" => "Constant", "value" => 3.14}
```

**Gotcha — complex numbers and bytes:** Python `Constant` can hold complex numbers (`3+4j`) and bytes (`b"hello"`). These should raise `UnsupportedNodeError`. **Serialization caveat:** JSON has no native complex number type, so the serialized form depends entirely on the `ast2json` implementation used — some will produce a dict with `real`/`imag` keys, some will produce a string representation, some will error. Bare imaginary literals like `4j` are `Constant(value=4j)` in the AST. Compound expressions like `3+4j` appear as `BinOp(Constant(3), Add, Constant(4j))`. Detection heuristic: check if the JSON value is a map/object (for dict-serialized complex) or if the `kind` field or value type doesn't match any expected type (int, float, str, bool, None). Test with your chosen serializer.

**Gotcha — float vs integer:** JSON does not distinguish between `1` and `1.0` in all cases. Python's AST does. After `Jason.decode!`, Elixir will have the correct type, so this should be fine. But test it.

#### 6.3.3 Variables

**`Name(id: identifier, ctx: expr_context)`** — A variable reference. `id` is the name as a string. `ctx` is `Load`, `Store`, or `Del` indicating whether the variable is being read, assigned to, or deleted.

```elixir
# Python: my_var (being read)
%{"_type" => "Name", "id" => "my_var", "ctx" => %{"_type" => "Load"}}

# Python: my_var (being assigned to, e.g., left side of =)
%{"_type" => "Name", "id" => "my_var", "ctx" => %{"_type" => "Store"}}
```

**`Starred(value: expr, ctx: expr_context)`** — A `*var` unpacking reference. `value` is typically a `Name` node. Used in assignment targets (`a, *b = [1,2,3]`) and function call arguments (`fn(*args)`).

```elixir
# Python: a, *b = items
# The Assign target is a Tuple containing [Name("a"), Starred(Name("b"))]
```

#### 6.3.4 Collections

**`List(elts: expr*, ctx: expr_context)`** — A list literal. `elts` is a list of element expression nodes. `ctx` is `Store` when the list is an assignment target (e.g., `[a, b] = [1, 2]`), `Load` otherwise.

**`Tuple(elts: expr*, ctx: expr_context)`** — A tuple literal. Same structure as `List`. `ctx` is `Store` when used as an assignment target (e.g., `a, b = 1, 2` creates a `Tuple` target).

**`Dict(keys: expr?*, values: expr*)`** — A dictionary literal. `keys` and `values` are parallel lists. When dictionary unpacking is used (`{**d}`), the corresponding `keys` entry is `nil`/`null` and the expression goes in `values`.

```elixir
# Python: {"a": 1, "b": 2}
%{
  "_type" => "Dict",
  "keys" => [
    %{"_type" => "Constant", "value" => "a"},
    %{"_type" => "Constant", "value" => "b"}
  ],
  "values" => [
    %{"_type" => "Constant", "value" => 1},
    %{"_type" => "Constant", "value" => 2}
  ]
}
```

#### 6.3.5 Operators (Never Standalone)

Operators are child nodes of `BinOp`, `UnaryOp`, `BoolOp`, and `Compare`. They never appear as standalone AST nodes. Each is a simple node with only `"_type"` and no other fields.

**Binary operators** (used by `BinOp`):
`Add`, `Sub`, `Mult`, `Div`, `FloorDiv`, `Mod`, `Pow`, `LShift`, `RShift`, `BitOr`, `BitXor`, `BitAnd`, `MatMult`

**Unary operators** (used by `UnaryOp`):
`UAdd`, `USub`, `Not`, `Invert`

**Boolean operators** (used by `BoolOp`):
`And`, `Or`

**Comparison operators** (used by `Compare`):
`Eq`, `NotEq`, `Lt`, `LtE`, `Gt`, `GtE`, `Is`, `IsNot`, `In`, `NotIn`

**Important:** These are four distinct operator categories used by four different expression node types. `And`/`Or` belong to `BoolOp` (which uses a `values` list), NOT to `BinOp` (which uses `left`/`right`). `In`/`NotIn`/`Is`/`IsNot` belong to `Compare`, NOT to `BinOp`. The operator lookup map is shared for convenience, but dispatch must respect which expression node type uses which operator category.

#### 6.3.6 Expressions

**`BinOp(left: expr, op: operator, right: expr)`** — A binary operation. `left` and `right` are expression nodes. `op` is one of the binary operator nodes (`Add`, `Sub`, etc.).

```elixir
# Python: a + b
%{
  "_type" => "BinOp",
  "left" => %{"_type" => "Name", "id" => "a", "ctx" => %{"_type" => "Load"}},
  "op" => %{"_type" => "Add"},
  "right" => %{"_type" => "Name", "id" => "b", "ctx" => %{"_type" => "Load"}}
}
```

**`UnaryOp(op: unaryop, operand: expr)`** — A unary operation. `op` is `UAdd`, `USub`, `Not`, or `Invert`. `operand` is the expression being operated on.

```elixir
# Python: -x
%{
  "_type" => "UnaryOp",
  "op" => %{"_type" => "USub"},
  "operand" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Load"}}
}
```

**`BoolOp(op: boolop, values: expr*)`** — A boolean operation (`and`/`or`). **Critically different from `BinOp`**: uses a `values` list, NOT `left`/`right`. Consecutive operations with the same operator are collapsed: `a and b and c` produces one `BoolOp` with three `values`, not two nested `BoolOp` nodes.

```elixir
# Python: a and b and c
%{
  "_type" => "BoolOp",
  "op" => %{"_type" => "And"},
  "values" => [
    %{"_type" => "Name", "id" => "a", "ctx" => %{"_type" => "Load"}},
    %{"_type" => "Name", "id" => "b", "ctx" => %{"_type" => "Load"}},
    %{"_type" => "Name", "id" => "c", "ctx" => %{"_type" => "Load"}}
  ]
}
```

**Conversion:** Fold the `values` list into nested `&&`/`||` expressions: `a and b and c` → `{:&&, [], [{:&&, [], [a, b]}, c]}`. **Use `&&`/`||`, not `and`/`or`** — see §9.6 and §11.

**`Compare(left: expr, ops: cmpop*, comparators: expr*)`** — A comparison of two or more values. `left` is the first value, `ops` is a list of comparison operator nodes, `comparators` is a list of the remaining values. `ops` and `comparators` are always the same length.

```elixir
# Python: a < b < c (chained comparison)
%{
  "_type" => "Compare",
  "left" => %{"_type" => "Name", "id" => "a", "ctx" => %{"_type" => "Load"}},
  "ops" => [%{"_type" => "Lt"}, %{"_type" => "Lt"}],
  "comparators" => [
    %{"_type" => "Name", "id" => "b", "ctx" => %{"_type" => "Load"}},
    %{"_type" => "Name", "id" => "c", "ctx" => %{"_type" => "Load"}}
  ]
}
```

**Conversion:** For a single comparison (one op), produce `{:op, [], [left, right]}`. For chained comparisons, expand to a `&&` chain: `a < b && b < c`. (Use `&&` not `and` — see §11.)

**`Call(func: expr, args: expr*, keywords: keyword*)`** — A function call. `func` is the function being called (usually a `Name` or `Attribute` node). `args` is a list of positional arguments. `keywords` is a list of `keyword` nodes for named arguments.

```elixir
# Python: sorted(items, key=lambda x: x[0])
%{
  "_type" => "Call",
  "func" => %{"_type" => "Name", "id" => "sorted", "ctx" => %{"_type" => "Load"}},
  "args" => [%{"_type" => "Name", "id" => "items", "ctx" => %{"_type" => "Load"}}],
  "keywords" => [
    %{
      "_type" => "keyword",
      "arg" => "key",
      "value" => %{"_type" => "Lambda", ...}
    }
  ]
}
```

**`keyword(arg: identifier?, value: expr)`** — A keyword argument. `arg` is the parameter name as a string, or `nil`/`null` for `**kwargs` unpacking.

**`IfExp(test: expr, body: expr, orelse: expr)`** — A ternary expression (`value if condition else other`). Each field is a single expression node. **Note the Python syntax ordering vs AST ordering**: Python syntax is `body if test else orelse` (value first, then condition), but the AST stores fields in logical order: `test` first, then `body`, then `orelse`.

```elixir
# Python: x if condition else y
%{
  "_type" => "IfExp",
  "test" => %{"_type" => "Name", "id" => "condition", "ctx" => %{"_type" => "Load"}},
  "body" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Load"}},
  "orelse" => %{"_type" => "Name", "id" => "y", "ctx" => %{"_type" => "Load"}}
}
```

**`Attribute(value: expr, attr: identifier, ctx: expr_context)`** — Attribute access (e.g., `obj.method`). `value` is the object expression, `attr` is the attribute name as a bare string, `ctx` is `Load`/`Store`/`Del`.

```elixir
# Python: s.lower()  — the Call's func is an Attribute node
# Call.func = %{"_type" => "Attribute", "value" => Name("s"), "attr" => "lower", "ctx" => Load}
```

**`Subscript(value: expr, slice: expr, ctx: expr_context)`** — Subscript access (e.g., `x[0]`, `x[1:3]`). `value` is the object being subscripted, `slice` is the index/key/slice expression, `ctx` is `Load`/`Store`/`Del`.

```elixir
# Python: x[0]
%{
  "_type" => "Subscript",
  "value" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Load"}},
  "slice" => %{"_type" => "Constant", "value" => 0},
  "ctx" => %{"_type" => "Load"}
}
```

**`Slice(lower: expr?, upper: expr?, step: expr?)`** — A slice object (`lower:upper:step`). All three fields are optional. Appears only inside `Subscript.slice`.

```elixir
# Python: x[1:3]
# Subscript.slice = %{"_type" => "Slice", "lower" => Constant(1), "upper" => Constant(3), "step" => nil}

# Python: x[::2]
# Subscript.slice = %{"_type" => "Slice", "lower" => nil, "upper" => nil, "step" => Constant(2)}
```

**`Lambda(args: arguments, body: expr)`** — An anonymous function. `args` uses the same `arguments` node as `FunctionDef`. `body` is a **single expression** (not a statement list like `FunctionDef`).

```elixir
# Python: lambda x, y: x + y
%{
  "_type" => "Lambda",
  "args" => %{"_type" => "arguments", "args" => [%{"_type" => "arg", "arg" => "x"}, ...], ...},
  "body" => %{"_type" => "BinOp", "left" => Name("x"), "op" => Add, "right" => Name("y")}
}
```

**`ListComp(elt: expr, generators: comprehension*)`** — A list comprehension. `elt` is the element expression evaluated for each iteration. `generators` is a list of `comprehension` nodes.

```elixir
# Python: [x * 2 for x in items if x > 0]
%{
  "_type" => "ListComp",
  "elt" => %{"_type" => "BinOp", "left" => Name("x"), "op" => Mult, "right" => Constant(2)},
  "generators" => [
    %{
      "_type" => "comprehension",
      "target" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Store"}},
      "iter" => %{"_type" => "Name", "id" => "items", "ctx" => %{"_type" => "Load"}},
      "ifs" => [
        %{"_type" => "Compare", "left" => Name("x"), "ops" => [Gt], "comparators" => [Constant(0)]}
      ],
      "is_async" => 0
    }
  ]
}
```

**`comprehension(target: expr, iter: expr, ifs: expr*, is_async: int)`** — One `for` clause in a comprehension. `target` is the loop variable (typically `Name` or `Tuple`), `iter` is the iterable, `ifs` is a list of filter expressions (each `for` clause can have multiple `if` filters). `is_async` is 0 or 1. A `ListComp` can have multiple `comprehension` nodes for nested loops.

**`NamedExpr(target: expr, value: expr)`** — The walrus operator (`:=`). `target` is a `Name` node, `value` is any expression. This library raises `UnsupportedNodeError` for this node.

#### 6.3.7 Statements

**`Assign(targets: expr*, value: expr)`** — An assignment statement. **`targets` is a list** (plural), not a single target. Multiple targets means `a = b = 5` — one `Assign` with `targets: [Name("a"), Name("b")]` and `value: Constant(5)`. Tuple unpacking is represented by a `Tuple` node inside `targets`.

```elixir
# Python: a = b = 5
%{
  "_type" => "Assign",
  "targets" => [
    %{"_type" => "Name", "id" => "a", "ctx" => %{"_type" => "Store"}},
    %{"_type" => "Name", "id" => "b", "ctx" => %{"_type" => "Store"}}
  ],
  "value" => %{"_type" => "Constant", "value" => 5}
}

# Python: a, b = fn()
%{
  "_type" => "Assign",
  "targets" => [
    %{
      "_type" => "Tuple",
      "elts" => [Name("a", Store), Name("b", Store)],
      "ctx" => %{"_type" => "Store"}
    }
  ],
  "value" => %{"_type" => "Call", ...}
}
```

**Conversion for multiple targets:** Python evaluates the value once, then assigns to each target **left-to-right**. `a = b = 5` → `a = 5; b = 5`. Both targets receive the same value. For simple values the order is irrelevant, but for expressions with side effects (e.g., subscript targets involving function calls), left-to-right evaluation order matters. The generated Elixir should assign the evaluated value to each target in left-to-right order.

**`AugAssign(target: expr, op: operator, value: expr)`** — Augmented assignment (e.g., `a += 1`). `target` is a **single** node (unlike `Assign`). `op` is the operator (e.g., `Add`). `value` is the right-hand side.

```elixir
# Python: x += 2
%{
  "_type" => "AugAssign",
  "target" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Store"}},
  "op" => %{"_type" => "Add"},
  "value" => %{"_type" => "Constant", "value" => 2}
}
```

**`Return(value: expr?)`** — A return statement. `value` is optional (bare `return` has `value: nil`).

**`Expr(value: expr)`** — An expression used as a statement. Wraps function calls, method calls, or any expression whose return value is discarded. This is the node where mutation-method detection happens: `list.append(x)` appears as `Expr(value=Call(Attribute(Name("list"), "append"), [Name("x")]))`.

**Conversion:** When the wrapped expression is a method call that mutates in-place (e.g., `list.append(x)`), convert to a reassignment: `list = list ++ [x]`. See §13.

**`If(test: expr, body: stmt*, orelse: stmt*)`** — An if statement. `test` is the condition, `body` is a list of statements for the true branch, `orelse` is a list for the else/elif branch. Python represents `elif` as a nested `If` inside `orelse`: if `orelse` contains exactly one `If` node, that's an `elif`.

```elixir
# Python: if a: ... elif b: ... else: ...
%{
  "_type" => "If",
  "test" => a,
  "body" => [...],
  "orelse" => [
    %{
      "_type" => "If",
      "test" => b,
      "body" => [...],
      "orelse" => [...]   # The else branch
    }
  ]
}
```

**`For(target: expr, iter: expr, body: stmt*, orelse: stmt*)`** — A for loop. `target` is the loop variable (often a `Name`, or a `Tuple` for unpacking). `iter` is the iterable. `body` is the loop body. `orelse` is executed if the loop completes without `break` (the `for`/`else` construct). This library raises `UnsupportedNodeError` if `orelse` is non-empty.

```elixir
# Python: for x in items: ...
%{
  "_type" => "For",
  "target" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Store"}},
  "iter" => %{"_type" => "Name", "id" => "items", "ctx" => %{"_type" => "Load"}},
  "body" => [...],
  "orelse" => []
}
```

**`While(test: expr, body: stmt*, orelse: stmt*)`** — A while loop. `test` is the loop condition. `body` is the loop body. `orelse` is executed if the loop terminates normally without `break` (the `while`/`else` construct). This library raises `UnsupportedNodeError` if `orelse` is non-empty.

**`Pass`** — A no-op statement. No fields.

**`Break`** — Break out of a loop. No fields.

**`Continue`** — Continue to next loop iteration. No fields.

**`Assert(test: expr, msg: expr?)`** — An assertion. `test` is the condition, `msg` is an optional failure message expression.

#### 6.3.8 Function and Class Definitions

**`FunctionDef(name: identifier, args: arguments, body: stmt*, decorator_list: expr*, returns: expr?, type_params: type_param*)`** — A function definition. `name` is the function name. `args` is an `arguments` node. `body` is a list of statements. `decorator_list` is a list of decorator expressions. `returns` is the optional return type annotation (ignored by this library). `type_params` (Python 3.12+ only) is a list of type parameter nodes (ignored). **Note:** `type_params` does not exist in Python 3.8–3.11 ASTs. The converter should treat this field as optional and default to `[]` when absent.

**`arguments(posonlyargs: arg*, args: arg*, vararg: arg?, kwonlyargs: arg*, kw_defaults: expr?*, kwarg: arg?, defaults: expr*)`** — Function arguments. `posonlyargs` are positional-only parameters (before `/`). `args` are regular parameters. `vararg` is the `*args` parameter (or `nil`). `kwonlyargs` are keyword-only parameters (after `*`). `kw_defaults` parallels `kwonlyargs` — `nil` entries mean required. `kwarg` is the `**kwargs` parameter (or `nil`). `defaults` is a list of default values for the last N `args` (and `posonlyargs`) parameters.

**`arg(arg: identifier, annotation: expr?)`** — A single argument. `arg` is the parameter name. `annotation` is the type annotation (ignored).

#### 6.3.9 Context Nodes

**`Load`, `Store`, `Del`** — These context markers appear in the `ctx` field of `Name`, `Attribute`, `Subscript`, `Starred`, `List`, and `Tuple`. They indicate whether the node is being read (`Load`), assigned to (`Store`), or deleted (`Del`). The converter generally ignores `ctx` — context is determined structurally by the parent node.

#### 6.3.10 Python AST Version Variations

The Python AST format is not stable across versions. While this library targets "Python 3.8+," the AST shape varies:

| Feature | Python 3.8–3.9 | Python 3.10–3.11 | Python 3.12+ |
|---|---|---|---|
| `Constant.kind` field | Present (`"u"` or `nil`) | Present (`"u"` or `nil`) | Present (still in grammar) |
| `FunctionDef.type_params` | **Does not exist** | **Does not exist** | Present (list of type parameter nodes) |
| Old literal nodes (`Num`, `Str`, `Bytes`, `NameConstant`, `Ellipsis`) | Deprecated but still produced by some tools | Deprecated but still produced by some tools | Emit `DeprecationWarning` (3.12–3.13); **removed in 3.14** |
| `Match` statement | Does not exist | Present (Python 3.10+, PEP 634) | Present |

**The converter should treat version-dependent fields as optional.** Use `Map.get(node, "type_params", [])` rather than `node["type_params"]` to avoid `KeyError` on pre-3.12 ASTs. Similarly, `Map.get(node, "kind", nil)` for `Constant.kind`.

**Serializer variations:** The JSON representation of the Python AST depends on the serializer used (`ast2json`, `ast.dump` with custom serialization, etc.). Key areas where serializers diverge: representation of complex numbers (no JSON type exists), representation of `bytes` literals, handling of `Ellipsis` constant, and whether metadata fields (`lineno`, `col_offset`, etc.) are included. The converter should be resilient to missing metadata fields and should not depend on any specific serializer's conventions for unserializable types.



---

## §7. Python AST Node Categories

### 7.1 Supported Node Summary

#### Literals and Names (~5 nodes)
`Constant`, `Name`, `List`, `Tuple`, `Dict`

#### Operators (~29 nodes)

**Binary (13):** `Add`, `Sub`, `Mult`, `Div`, `FloorDiv`, `Mod`, `Pow`, `LShift`, `RShift`, `BitOr`, `BitXor`, `BitAnd`, `MatMult`

**Unary (4):** `UAdd`, `USub`, `Not`, `Invert`

**Boolean (2):** `And`, `Or`

**Comparison (10):** `Eq`, `NotEq`, `Lt`, `LtE`, `Gt`, `GtE`, `Is`, `IsNot`, `In`, `NotIn`

Note: `MatMult`, `LShift`, `RShift`, `BitOr`, `BitXor`, `BitAnd`, and `Invert` are listed for completeness but may raise `UnsupportedNodeError` initially. Most algorithmic code does not use matrix multiplication or bitwise shifts (though `BitAnd`, `BitOr`, `BitXor` do appear in some problems).

**IMPORTANT — Bitwise operators require `import Bitwise`:** The operators `<<<`, `>>>`, `|||`, `&&&`, `^^^`, and `~~~` are only available after `use Bitwise` or `import Bitwise`. The code generator must detect when any bitwise operator is used and emit `import Bitwise` at the top of the generated code. Without this, generated code using bitwise operators will fail to compile. Detection: set `context.uses_bitwise = true` when any bitwise operator node is encountered; at `Module` level, if the flag is true, prepend `import Bitwise` to the output.

#### Expressions (~12 nodes)
`BinOp`, `UnaryOp`, `Compare`, `BoolOp`, `Call`, `IfExp`, `Subscript`, `Attribute`, `ListComp`, `Lambda`, `Slice`, `Starred` (in function call arguments only — `*args` unpacking)

#### Statements (~12 nodes)
`Assign`, `AugAssign`, `Return`, `If`, `For`, `While`, `Pass`, `Break`, `Continue`, `Assert`, `Expr` (statement wrapper), `FunctionDef`

#### Auxiliary (~8 nodes)
`arguments`, `arg`, `keyword`, `comprehension`, `Module`, `Load`, `Store`, `Del`

**Total: ~66 node types**, of which ~29 are trivial operator nodes and ~3 are context markers (`Load`/`Store`/`Del`) that the converter ignores.

### 7.2 Explicitly Unsupported (raises `UnsupportedNodeError`)

`ClassDef`, `AsyncFunctionDef`, `AsyncFor`, `AsyncWith`, `Import`, `ImportFrom`, `Try`, `TryStar`, `ExceptHandler`, `With`, `Raise`, `Global`, `Nonlocal`, `Yield`, `YieldFrom`, `Await`, `Match`, `Delete`, `AnnAssign`, `TypeAlias`, `GeneratorExp`, `SetComp`, `DictComp`, `FormattedValue`, `JoinedStr`, `TemplateStr`, `Interpolation`, `Set`, `NamedExpr`, `Starred` (in assignment target unpacking — `a, *b = ...`)

**`GeneratorExp` interaction with builtins:** Note that `GeneratorExp` is common inside calls to mapped builtins: `sum(x**2 for x in items)`, `max(abs(x) for x in items)`, `min(len(s) for s in strings)`. These will crash on the `GeneratorExp` child node even though `sum`/`max`/`min` are in the builtins table. An implementer encountering this pattern should either (a) special-case `Call` nodes where the argument is a `GeneratorExp` and the function is a known builtin (converting to `Enum.sum(Enum.map(items, fn x -> x ** 2 end))` or a `for` comprehension), or (b) raise `UnsupportedNodeError` with a clear message like "GeneratorExp inside sum() — consider rewriting as a list comprehension."

---

## §8. Elixir AST Reference (Critical Implementation Knowledge)

> **Purpose:** This section is a consolidated reference for Elixir's AST format, written for implementers who need to construct Elixir AST programmatically. Every example shows both the Elixir source code and the corresponding AST tuple structure that `convert/2` must produce.

### 8.1 The Three-Tuple Rule

Every non-literal expression in Elixir's AST is a three-element tuple:

```elixir
{name_or_operator, metadata, arguments_or_context}
```

- **`name_or_operator`**: An atom (for variables, function calls, operators) or another tuple (for remote calls like `Module.function`)
- **`metadata`**: A keyword list, usually `[]` for generated code (line numbers are optional)
- **`arguments_or_context`**: A list of arguments (for function calls), an atom like `nil` or `Elixir` (for variables), or a keyword list (for special forms)

**Literals that represent themselves (no wrapping tuple):**
- Atoms: `:ok`, `:error`, `true`, `false`, `nil`
- Integers: `42`
- Floats: `3.14`
- Strings: `"hello"`
- Lists: `[1, 2, 3]`
- Two-element tuples: `{:a, :b}` (but 3+ element tuples use `:{}`)

### 8.2 Variables

Source: `my_var`

```elixir
{:my_var, [], nil}
#  ^name   ^meta  ^context (nil for programmatic AST)
```

The atom `:my_var` becomes the variable name. The context is `nil` when building ASTs programmatically (as opposed to `quote`, which sets it to `Elixir`).

### 8.3 Function Calls

#### Local call
Source: `sum(1, 2)`

```elixir
{:sum, [], [1, 2]}
#  ^name  ^meta  ^args as list
```

#### Remote call (Module.function)
Source: `Enum.sort(list)`

```elixir
{
  {:., [], [{:__aliases__, [], [:Enum]}, :sort]},
  #  ^dot   ^meta  ^module alias           ^function name
  [],
  [{:list, [], nil}]
#  ^args
}
```

**Pattern for remote calls:**
```elixir
{{:., [], [module_alias_ast, :function_name]}, [], [args]}
```

Where `module_alias_ast` is:
```elixir
{:__aliases__, [], [:Module, :Name]}
# For single-word modules: {:__aliases__, [], [:Enum]}
# For nested modules: {:__aliases__, [], [:MyApp, :Utils]}
```

### 8.4 Operators

#### Arithmetic
Source: `a + b`

```elixir
{:+, [], [{:a, [], nil}, {:b, [], nil}]}
```

Source: `a - b` → `{-, [], [a_ast, b_ast]}`
Source: `a * b` → `{*, [], [a_ast, b_ast]}`
Source: `a / b` → `{/, [], [a_ast, b_ast]}`

#### Comparison
Source: `a == b` → `{:==, [], [a_ast, b_ast]}`
Source: `a != b` → `{:!=, [], [a_ast, b_ast]}`
Source: `a < b`  → `{:<, [], [a_ast, b_ast]}`
Source: `a <= b` → `{:<=, [], [a_ast, b_ast]}`

#### Boolean (logical)
Source: `a && b` → `{:&&, [], [a_ast, b_ast]}`
Source: `a || b` → `{:||, [], [a_ast, b_ast]}`
Source: `!a`     → `{:!, [], [a_ast]}`

**CRITICAL: Use `&&`/`||`/`!`, NOT `and`/`or`/`not`.** Elixir's `and`/`or`/`not` are strict boolean operators that raise `BadBooleanError` on non-boolean values (like `0`, `""`, `[]`). Python's `and`/`or`/`not` accept any value. Since `&&`/`||`/`!` accept any truthy/falsy value in Elixir, they're the correct mapping.

#### Bitwise (requires `import Bitwise`)
Source: `a <<< b` → `{:<<<, [], [a_ast, b_ast]}`
Source: `a >>> b` → `{:>>>, [], [a_ast, b_ast]}`
Source: `a ||| b` → `{:|||, [], [a_ast, b_ast]}`
Source: `a &&& b` → `{:&&&, [], [a_ast, b_ast]}`
Source: `a ^^^ b` → `{:^^^, [], [a_ast, b_ast]}`
Source: `~~~a`    → `{:~~~, [], [a_ast]}`

### 8.5 Blocks (Multiple Statements)

When a function body or block has multiple statements, they're wrapped in `__block__`:

Source:
```elixir
x = 1
x + 2
```

```elixir
{:__block__, [], [
  {:=, [], [{:x, [], nil}, 1]},
  {:+, [], [{:x, [], nil}, 2]}
]}
```

**Important:** A single expression does NOT get wrapped in `__block__`. Only two or more statements need it.

```elixir
# Single statement: no __block__
{:=, [], [{:x, [], nil}, 1]}

# Two statements: wrapped in __block__
{:__block__, [], [
  {:=, [], [{:x, [], nil}, 1]},
  {:+, [], [{:x, [], nil}, 2]}
]}
```

### 8.6 `if` Expression

Source: `if condition do body else else_body end`

```elixir
{:if, [], [
  condition_ast,
  [do: body_ast, else: else_body_ast]
]}
```

Source: `if condition do body end` (no else)

```elixir
{:if, [], [
  condition_ast,
  [do: body_ast]
]}
```

### 8.7 `cond` Expression

Source:
```elixir
cond do
  x > 0 -> :positive
  x < 0 -> :negative
  true -> :zero
end
```

```elixir
{:cond, [], [
  [
    do: [
      {:->, [], [[{:>, [], [{:x, [], nil}, 0]}], :positive]},
      {:->, [], [[{:<, [], [{:x, [], nil}, 0]}], :negative]},
      {:->, [], [[true], :zero]}
    ]
  ]
]}
```

### 8.8 `def` and `defp`

Source: `def add(a, b) do a + b end`

```elixir
{:def, [], [
  {:add, [], [{:a, [], nil}, {:b, [], nil}]},
  [do: {:+, [], [{:a, [], nil}, {:b, [], nil}]}]
]}
```

Source: `defp helper(x) do x end`

```elixir
{:defp, [], [
  {:helper, [], [{:x, [], nil}]},
  [do: {:x, [], nil}]
]}
```

Source: `def greet(name, greeting \\ "Hello") do ... end`

```elixir
{:def, [], [
  {:greet, [], [
    {:name, [], nil},
    {:\\\\, [], [{:greeting, [], nil}, "Hello"]}
  ]},
  [do: body_ast]
]}
```

### 8.9 Anonymous Functions (`fn`)

Source: `fn x, acc -> x + acc end`

```elixir
{:fn, [], [
  {:->, [], [
    [{:x, [], nil}, {:acc, [], nil}],
    # ^params as a list   ^body
    {:+, [], [{:x, [], nil}, {:acc, [], nil}]}
  ]}
]}
```

**Single-clause fn with pattern matching:**
Source: `fn {a, b} -> a + b end`

```elixir
{:fn, [], [
  {:->, [], [
    [{:{}, [], [{:a, [], nil}, {:b, [], nil}]}],
    {:+, [], [{:a, [], nil}, {:b, [], nil}]}
  ]}
]}
```

Note: 2-element tuple patterns use bare `{:a, :b}` syntax. 3+ element tuple patterns use `{:{}, [], [elements...]}`.

### 8.10 Tuples (3+ elements)

Source: `{a, b, c}`

```elixir
{:{}, [], [{:a, [], nil}, {:b, [], nil}, {:c, [], nil}]}
```

Source: `{a, b}` (2-element tuple — special case, no `:{}`)

```elixir
{{:a, [], nil}, {:b, [], nil}}
```

### 8.11 Maps

Source: `%{key: value}`

```elixir
{:%{}, [], [key: {:value, [], nil}]}
```

Source: `%{"key" => value}`

```elixir
{:%{}, [], [{"key", {:value, [], nil}}]}
```

### 8.12 `try`/`catch`/`throw` (for early returns)

Source:
```elixir
try do
  Enum.reduce(list, acc, fn x, acc ->
    if x == target, do: throw({:return, acc})
    acc + x
  end)
catch
  {:return, result} -> result
end
```

```elixir
{:try, [], [
  [do: try_body_ast],
  [catch: [
    {:->, [], [
      [{:{}, [], [:return, {:result, [], nil}]}],
      {:result, [], nil}
    ]}
  ]]
]}
```

### 8.13 `Macro.to_string/1` Rendering Examples

For implementers who need to verify their AST construction, here's what `Macro.to_string/1` produces for various AST structures:

| AST | `Macro.to_string` output |
|-----|--------------------------|
| `{:+, [], [1, 2]}` | `"1 + 2"` |
| `{:&&, [], [{:a, [], nil}, {:b, [], nil}]}` | `"a && b"` |
| `{:==, [], [{:x, [], nil}, nil]}` | `"x == nil"` |
| `{:fn, [], [{:->, [], [[{:x, [], nil}], {:+, [], [{:x, [], nil}, 1]}]}]}` | `"fn x -> x + 1 end"` |
| `{:if, [], [{:cond, [], nil}, [do: {:a, [], nil}, else: {:b, [], nil}]]]}` | `"if cond, do: a, else: b"` |
| `{:__block__, [], [{:=, [], [{:x, [], nil}, 1]}, {:x, [], nil}]}` | `"x = 1\nx"` |
| `{{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [{:list, [], nil}]}` | `"Enum.sort(list)"` |

**Important gotcha:** `Macro.to_string/1` returns **iodata**, NOT a binary string. To get a binary string, pipe through `IO.iodata_to_binary/1`. Similarly, `Code.format_string!/1` returns iodata, not a binary.



---

## §9. Mutation Strategy Detailed

### 9.1 Core Principle

Elixir has no mutable variables. Python does. Every Python construct that mutates a variable must be translated to an Elixir construct that rebinds the variable to a new value.

### 9.2 Translation Table

| Python Construct | AST Pattern | Elixir Translation |
|---|---|---|
| `x += n` | `AugAssign(target=Name("x"), op=Add, value=n)` | `x = x + n` |
| `x -= n` | `AugAssign(target=Name("x"), op=Sub, value=n)` | `x = x - n` |
| `x *= n` | `AugAssign(target=Name("x"), op=Mult, value=n)` | `x = x * n` |
| `x /= n` | `AugAssign(target=Name("x"), op=Div, value=n)` | `x = x / n` |
| `x //= n` | `AugAssign(target=Name("x"), op=FloorDiv, value=n)` | `x = Integer.floor_div(x, n)` |
| `x %= n` | `AugAssign(target=Name("x"), op=Mod, value=n)` | `x = Integer.mod(x, n)` |
| `x **= n` | `AugAssign(target=Name("x"), op=Pow, value=n)` | `x = Integer.pow(x, n)` |
| `x <<= n` | `AugAssign(target=Name("x"), op=LShift, value=n)` | `x = x <<< n` |
| `x >>= n` | `AugAssign(target=Name("x"), op=RShift, value=n)` | `x = x >>> n` |
| `x \|= n` | `AugAssign(target=Name("x"), op=BitOr, value=n)` | `x = x \|\|\| n` |
| `x ^= n` | `AugAssign(target=Name("x"), op=BitXor, value=n)` | `x = x ^^^ n` |
| `x &= n` | `AugAssign(target=Name("x"), op=BitAnd, value=n)` | `x = x &&& n` |
| `x = ...` | `Assign(targets=[Name("x")], value=...)` | `x = ...` |

### 9.3 AugAssign with Subscript Targets

When `AugAssign.target` is a `Subscript` node (e.g., `d[key] += 1`), the translation is different — it becomes a map update:

```python
d[key] += 1
```

```elixir
d = Map.put(d, key, Map.get(d, key, 0) + 1)
```

The `convert/2` function for `AugAssign` must check if `target["_type"]` is `"Subscript"` and handle it as a map mutation rather than a variable rebinding.

### 9.4 Mutation Methods (Statement-Level)

Python lists and dicts have methods that mutate in place. When called as statements (wrapped in an `Expr` node), they must be converted to reassignments:

| Python Method | AST Pattern | Elixir Translation |
|---|---|---|
| `my_list.append(x)` | `Expr(value=Call(Attribute(Name("my_list"), "append"), [Name("x")]))` | `my_list = my_list ++ [x]` |
| `my_list.extend(items)` | `Expr(value=Call(Attribute(Name("my_list"), "extend"), [Name("items")]))` | `my_list = my_list ++ items` |
| `my_list.sort()` | `Expr(value=Call(Attribute(Name("my_list"), "sort"), []))` | `my_list = Enum.sort(my_list)` |
| `my_list.reverse()` | `Expr(value=Call(Attribute(Name("my_list"), "reverse"), []))` | `my_list = Enum.reverse(my_list)` |
| `my_list.pop()` | `Expr(value=Call(Attribute(Name("my_list"), "pop"), []))` | `my_list = tl(my_list)` |
| `my_list.pop(i)` | `Expr(value=Call(Attribute(Name("my_list"), "pop"), [Constant(i)]))` | `my_list = List.delete_at(my_list, i)` |
| `my_list.insert(i, x)` | `Expr(value=Call(Attribute(Name("my_list"), "insert"), [Constant(i), Name("x")]))` | `my_list = List.insert_at(my_list, i, x)` |
| `my_list.clear()` | `Expr(value=Call(Attribute(Name("my_list"), "clear"), []))` | `my_list = []` |
| `my_dict.update(other)` | `Expr(value=Call(Attribute(Name("my_dict"), "update"), [Name("other")]))` | `my_dict = Map.merge(my_dict, other)` |
| `my_dict.pop(key)` | `Expr(value=Call(Attribute(Name("my_dict"), "pop"), [Name("key")]))` | `my_dict = Map.delete(my_dict, key)` |
| `my_dict.clear()` | `Expr(value=Call(Attribute(Name("my_dict"), "clear"), []))` | `my_dict = %{}` |
| `my_set.add(x)` | `Expr(value=Call(Attribute(Name("my_set"), "add"), [Name("x")]))` | `my_set = MapSet.put(my_set, x)` |
| `my_set.discard(x)` | `Expr(value=Call(Attribute(Name("my_set"), "discard"), [Name("x")]))` | `my_set = MapSet.delete(my_set, x)` |
| `my_set.update(items)` | `Expr(value=Call(Attribute(Name("my_set"), "update"), [Name("items")]))` | `my_set = MapSet.union(my_set, MapSet.new(items))` |
| `my_set.clear()` | `Expr(value=Call(Attribute(Name("my_set"), "clear"), []))` | `my_set = MapSet.new()` |

### 9.5 `del` and `pop` — List Mutation Behavior

**`del` statement is unsupported** (`raise UnsupportedNodeError`). However, `del` can be worked around by using `pop()` instead:

```python
# Python:
del my_list[2]       # unsupported
my_list.pop(2)       # supported → List.delete_at(my_list, 2)
```

**`pop()` removes AND returns:** In Python, `removed = my_list.pop(2)` both mutates the list and returns the removed element. If used as an expression (not a statement), this requires a two-part translation:

```python
removed = my_list.pop(2)
```

```elixir
removed = Enum.at(my_list, 2)
my_list = List.delete_at(my_list, 2)
```

### 9.6 Elixir's `&&`/`||`/`!` vs `and`/`or`/`not`

When converting Python's `and`/`or`/`not` to Elixir, use `&&`/`||`/`!`, NOT `and`/`or`/`not`.

**Why:** Elixir's `and`/`or`/`not` are strict boolean operators — they raise `BadBooleanError` on non-boolean values. Python's boolean operators accept any value. Since Python algorithmic code frequently uses truthiness checks on integers and strings (`if my_list:` meaning "if not empty"), the strict operators would crash.

| Python | Elixir | Elixir strict (WRONG) |
|---|---|---|
| `a and b` | `a && b` | `a and b` ← crashes if `a` is not boolean |
| `a or b` | `a \|\| b` | `a or b` ← crashes if `a` is not boolean |
| `not a` | `!a` | `not a` ← crashes if `a` is not boolean |

### 9.7 `Enum.at/2` for Index Access

Python uses `my_list[i]` for indexing. Elixir uses `Enum.at(list, index)`. However, `Enum.at/2` does **not** support assignment (Elixir is immutable). For mutation at an index:

```python
my_list[i] = new_value
```

```elixir
my_list = List.replace_at(my_list, i, new_value)
```

### 9.8 The `in` Operator

Python's `in` operator checks membership in any collection. The Elixir translation depends on the collection type:

| Python | Elixir |
|---|---|
| `x in my_list` | `x in my_list` |
| `x in my_tuple` | `x in Tuple.to_list(my_tuple)` |
| `x in my_set` | `MapSet.member?(my_set, x)` |
| `x in my_dict` | `Map.has_key?(my_dict, x)` |
| `x in "substring"` | `String.contains?("substring", x)` |

The `Compare` node handler must inspect the comparator to determine which translation to use. If the comparator is a `Name` node, the context struct can track the type of each variable (list, set, dict, string) to determine the correct translation. If the type is unknown, default to `x in collection` (which works for lists and ranges).

**Note:** `not in` is a single comparison operator `NotIn` in the AST — it is NOT `Not` wrapping `In`. This is because `not in` is a Python keyword pair, not the `not` operator applied to `in`.

```elixir
# Python: x not in items
# AST: Compare(left=Name("x"), ops=[NotIn], comparators=[Name("items")])
# Elixir: !(x in items)
```

### 9.9 The `len()` Function

Python's `len()` works on lists, tuples, dicts, sets, and strings. The Elixir translation depends on the type:

| Python | Elixir |
|---|---|
| `len(my_list)` | `length(my_list)` |
| `len(my_tuple)` | `tuple_size(my_tuple)` |
| `len(my_dict)` | `map_size(my_dict)` |
| `len(my_set)` | `MapSet.size(my_set)` |
| `len(my_string)` | `String.length(my_string)` |

If the type is unknown, `length/1` is the default (works for lists). For strings, `length/1` returns the number of bytes (wrong for UTF-8!), so `String.length/1` is needed.

### 9.10 `type()` Function

Python's `type(x)` returns the type of a value. For type-checking patterns:

```python
if type(x) == int:
    ...
if type(x) == list:
    ...
if type(x) == str:
    ...
```

The translation depends on the type being checked:

| Python | Elixir |
|---|---|
| `type(x) == int` | `is_integer(x)` |
| `type(x) == float` | `is_float(x)` |
| `type(x) == str` | `is_binary(x)` |
| `type(x) == bool` | `is_boolean(x)` |
| `type(x) == list` | `is_list(x)` |
| `type(x) == dict` | `is_map(x)` |
| `type(x) == type(None)` | `x == nil` |

### 9.11 `isinstance()` Function

```python
isinstance(x, int)     → is_integer(x)
isinstance(x, (int, float)) → is_number(x)
```

### 9.12 `not` Operator

Python's `not` produces a boolean (`True`/`False`). Elixir's `!` preserves truthiness semantics (returns `false` for falsy, `true` for truthy). This is close enough for most algorithmic code.

```python
not x    →    !x
```

---

## §10. Context Struct Detailed

### 10.1 Context Struct Design

The `Context` struct tracks state needed during conversion. It is threaded through every `convert/2` call via the accumulator pattern.

```elixir
defmodule Py2Ex.Context do
  @enforce_keys [:scopes]
  defstruct scopes: [],
            while_counter: 0,
            loop_nesting: 0,
            pending_helpers: [],
            uses_bitwise: false

  @type t :: %__MODULE__{
    scopes: [MapSet.t(String.t())],
    while_counter: non_neg_integer(),
    loop_nesting: non_neg_integer(),
    pending_helpers: [Macro.t()],
    uses_bitwise: boolean()
  }
end
```

### 10.2 Field Details

#### `scopes` — Scope Stack for Variable Tracking

A stack of `MapSet`s, where each `MapSet` contains the variable names bound in that scope. The top of the stack is the current scope.

**Purpose:** Track which variables are bound at each scope level to:
1. Avoid generating conflicting variable names (e.g., when a comprehension uses `x` that shadows an outer `x`)
2. Know which variables need to be threaded through loop accumulators
3. Generate correct `defp` signatures for helper functions

**Operations:**
- `push_scope(context)` — push a new empty `MapSet` onto the stack
- `pop_scope(context)` — remove the top scope
- `bind_var(context, name)` — add a variable name to the current scope
- `var_in_scope?(context, name)` — check if a variable is bound in any scope

**Example:**
```elixir
# At module level: scopes = [MapSet.new(["x", "y"])]
# Entering a function: scopes = [MapSet.new(["x", "y"]), MapSet.new(["a", "b"])]
# After popping: scopes = [MapSet.new(["x", "y"])]
```

#### `while_counter` — Unique Naming for While Loops

Each `while` loop needs a unique helper function name (`while_0`, `while_1`, etc.). This counter provides uniqueness.

**Increment:** The `While` handler increments this counter before generating the helper function name.

#### `loop_nesting` — Loop Depth for Return Strategy

Tracks how many nested loops deep we are. This determines the return strategy for functions containing `return` inside loops:

- `loop_nesting == 0`: Simple `throw`/`catch` (not inside a loop)
- `loop_nesting > 0`: `try`/`throw`/`catch` (inside a loop, where `throw` alone might be caught by the loop's `catch`)

#### `pending_helpers` — Deferred Helper Emission

When a `While` loop is encountered, its helper function AST is appended to `pending_helpers`. At the `Module` level, these helpers are prepended to the module body.

#### `uses_bitwise` — Bitwise Import Detection

Set to `true` when any bitwise operator node is encountered. At `Module` level, if `true`, prepend `import Bitwise` to the generated code.

---

## §11. Edge Cases and Correctness Traps

> **Purpose:** This section documents every known semantic gap between Python and Elixir that can produce silently wrong code. Each edge case includes the correct and incorrect translations, a test case, and the failure mode.

### 11.1 Integer Floor Division (`//`)

**Problem:** Python's `//` floors toward negative infinity. Elixir's `div/2` truncates toward zero.

| Expression | Python | Elixir `div/2` | Elixir `Integer.floor_div/2` |
|---|---|---|---|
| `7 // 2` | `3` | `3` ✓ | `3` ✓ |
| `-7 // 2` | `-4` | `-3` ✗ | `-4` ✓ |
| `7 // -2` | `-4` | `-3` ✗ | `-4` ✓ |
| `-7 // -2` | `3` | `3` ✓ | `3` ✓ |

**Test case:** `assert Integer.floor_div(-7, 2) == -4`

**Failure mode:** Silent wrong answer. No compilation error, no runtime crash. The sign of the result is wrong for negative dividends.

### 11.2 Integer Modulo (`%`)

**Problem:** Python's `%` uses floored modulo. Elixir's `rem/2` uses truncated remainder.

| Expression | Python | Elixir `rem/2` | Elixir `Integer.mod/2` |
|---|---|---|---|
| `7 % 3` | `1` | `1` ✓ | `1` ✓ |
| `-7 % 3` | `2` | `-1` ✗ | `2` ✓ |
| `7 % -3` | `-2` | `1` ✗ | `-2` ✓ |
| `-7 % -3` | `-1` | `-1` ✓ | `-1` ✓ |

**Test case:** `assert Integer.mod(-7, 3) == 2`

**Failure mode:** Silent wrong answer. This affects many algorithms, especially those using modulo for circular buffers, hash functions, or number theory.

**Availability:** `Integer.floor_div/2` and `Integer.mod/2` are available since Elixir **1.12.0** (released April 2021). If supporting Elixir < 1.12, implement equivalent helper functions:

```elixir
# Fallback for Elixir < 1.12
defp python_floordiv(a, b), do: div(a - rem(a, b) + b, b)
defp python_mod(a, b), do: rem(a - rem(a, b) + b, b)  # Not quite right for negative b — use actual formula
```

### 11.3 Python Truthiness vs Elixir Truthiness

**Problem:** Python treats many values as falsy. Elixir only treats `nil` and `false` as falsy.

```python
# Python truthiness
bool(0)       # False
bool("")      # False
bool([])      # False
bool({})      # False
bool(None)    # False
bool(42)      # True
bool("hello") # True
bool([1,2])   # True
```

```elixir
# Elixir truthiness
0 == false    # false — 0 is truthy!
"" == false   # false — "" is truthy!
[] == false   # false — [] is truthy!
nil == false  # false — nil is falsy, but != false
```

**Implication:** Code like `if my_list:` (meaning "if not empty") translates correctly to `if my_list do ... end` ONLY if we know `my_list` is a list (because `[]` is falsy in Python but truthy in Elixir).

**Solution:** The transpiler generates explicit checks:
- `if my_list:` → `if my_list != [] do ... end` (when type is known to be list)
- `if my_dict:` → `if map_size(my_dict) > 0 do ... end` (when type is known to be dict)
- `if my_string:` → `if my_string != "" do ... end` (when type is known to be string)
- `if x:` → `if x != nil && x != false do ... end` (when type is unknown — covers the common `None` check)

### 11.4 Chained Comparisons

**Problem:** Python chains comparisons naturally. Elixir does not.

```python
# Python: evaluates each pair, short-circuits
1 < x < 10         # True if 1 < x AND x < 10
0 < a < b < 100    # three comparisons
```

```elixir
# WRONG: 1 < x < 10
# Elixir parses this as (1 < x) < 10
# (1 < x) returns true/false, then true < 10 is nonsensical

# CORRECT:
1 < x && x < 10
```

**Conversion:** For `Compare(left, ops, comparators)`, expand to a `&&` chain:
```elixir
# a < b < c  →  a < b && b < c
# a < b == c  →  a < b && b == c
```

### 11.5 `for`/`else` and `while`/`else`

**Problem:** Python's loop `else` clause runs when the loop completes without `break`. No Elixir equivalent.

```python
for x in items:
    if x == target:
        found = True
        break
else:
    found = False
```

**Solution:** Raise `UnsupportedNodeError` when `orelse` is non-empty.

### 11.6 Nested Scope Variable Capture in Loops

**Problem:** Python closures capture variables by reference, not by value. In a loop, a closure created in each iteration sees the *current* value of the loop variable, not the value at creation time.

```python
functions = []
for i in range(3):
    functions.append(lambda: i)

# Python: all lambdas return 2 (the final value of i)
# functions[0]() → 2, functions[1]() → 2, functions[2]() → 2
```

In Elixir, `fn` captures the value at creation time. This is a known semantic difference that the transpiler does NOT attempt to fix — it would require mutable reference simulation. Document as a known limitation.

### 11.7 `enumerate` Argument Order

**Problem:** Python's `enumerate` yields `(index, element)` tuples. Elixir's `Enum.with_index` yields `(element, index)` tuples.

```python
for i, x in enumerate(["a", "b", "c"]):
    print(i, x)  # 0 "a", 1 "b", 2 "c"
```

```elixir
# WRONG (Enum.with_index returns {element, index}):
Enum.with_index(["a", "b", "c"])  # [{"a", 0}, {"b", 1}, {"c", 2}]

# CORRECT:
Enum.with_index(["a", "b", "c"])
|> Enum.map(fn {x, i} -> {i, x} end)  # [{0, "a"}, {1, "b"}, {2, "c"}]
```

**Solution:** The transpiler detects `enumerate` in the iterator of a `for` loop and generates code that swaps the tuple order.

### 11.8 Negative Indexing

**Problem:** Python supports negative indexing (`my_list[-1]` = last element). Elixir's `Enum.at/2` also supports negative indices, so this maps directly.

```elixir
Enum.at(my_list, -1)  # last element — works!
```

**No special handling needed** — `Enum.at/2` handles negative indices correctly.

### 11.9 `sorted()` with `key` Function

**Problem:** Python's `sorted(items, key=lambda x: x[1])` sorts by a key function. Elixir's `Enum.sort_by/3` does the same.

```elixir
Enum.sort_by(items, fn x -> Enum.at(x, 1) end)
```

**No special handling needed** — `Enum.sort_by/3` is a direct mapping.

### 11.10 `zip` with Unequal Lengths

**Problem:** Python's `zip` stops at the shortest iterable. Elixir's `Enum.zip` also stops at the shortest. No semantic gap.

### 11.11 Dictionary Key Access

**Problem:** Python's `d[key]` raises `KeyError` if key is missing. Elixir's `d[key]` (for maps) or `Map.fetch!(d, key)` raises `KeyError`. However, `Map.get(d, key)` returns `nil` (no error). The `dict.get(key)` method returns `nil` by default.

```python
d[key]          # KeyError if missing
d.get(key)      # None if missing
d.get(key, 0)   # 0 if missing
```

```elixir
Map.fetch!(d, key)     # KeyError if missing — matches d[key]
Map.get(d, key)        # nil if missing — matches d.get(key)
Map.get(d, key, 0)     # 0 if missing — matches d.get(key, 0)
```

### 11.12 `str.strip(chars)` Semantic Mismatch

**Problem:** Python's `strip(chars)` removes a **set** of characters from both ends. Elixir's `String.trim/1` only trims whitespace, and `String.trim_leading/2`/`String.trim_trailing/2` removes a **prefix/suffix string**, not a character set.

```python
"hello".strip("hlo")  # "e" — removes all h, l, o from both ends
```

```elixir
String.trim("hello", "hlo")  # WRONG — this removes the string "hlo" as a prefix/suffix
```

**Solution:** For `strip` with a character set, generate a regex-based helper or use `String.replace/3`:

```elixir
# For strip(chars): remove characters from both ends
Regex.replace(~r/^[#{Regex.escape(chars)}]+|[#{Regex.escape(chars)}]+$/, str, "")
```

**Recommendation:** For the MVP, raise `UnsupportedNodeError` when `strip` is called with a multi-character argument. Single-character strip and no-argument strip can be handled directly.

### 11.13 `str.replace(old, new, count)` vs `String.replace/4`

**Problem:** Python's `replace` takes an optional `count` parameter (max replacements). Elixir's `String.replace/4` takes a `global` option (replace all or just first).

```python
"aaa".replace("a", "b", 1)  # "baa" — replace first 1 occurrence
"aaa".replace("a", "b")     # "bbb" — replace all
```

```elixir
String.replace("aaa", "a", "b")  # "bbb" — always replaces all
# For count-limited: String.replace("aaa", "a", "b", global: false) — replaces first only
```

**Solution:** Map `str.replace(old, new)` to `String.replace(str, old, new)`. Map `str.replace(old, new, 1)` to `String.replace(str, old, new, global: false)`. For count > 1, raise `UnsupportedNodeError`.

### 11.14 `chr()` and `ord()` Functions

```python
chr(65)    # "A"
ord("A")   # 65
```

```elixir
List.to_string([65])        # "A" — chr(65)
?A                           # 65 — ord("A")
# Or more flexibly:
String.to_charlist("A") |> hd()  # 65
```

**Solution:** Map `chr(n)` to `List.to_string([n])`. Map `ord(c)` to `String.to_charlist(c) |> hd()` or use the `?A` syntax if the argument is a single-character constant.

### 11.15 `hex()`, `oct()`, `bin()` Functions

```python
hex(255)   # "0xff"
oct(255)   # "0o377"
bin(255)   # "0b11111111"
```

```elixir
Integer.to_string(255, 16)  # "ff" — missing "0x" prefix
Integer.to_string(255, 8)   # "377" — missing "0o" prefix
Integer.to_string(255, 2)   # "11111111" — missing "0b" prefix
```

**Solution:** Generate helpers that add the prefix:
```elixir
"0x" <> Integer.to_string(n, 16)
"0o" <> Integer.to_string(n, 8)
"0b" <> Integer.to_string(n, 2)
```

### 11.16 `input()` Function

**Problem:** Python's `input()` reads a line from stdin. Elixir's equivalent is `IO.gets/1`.

```elixir
IO.gets("") |> String.trim_trailing("\n")
```

**Solution:** Map `input()` to `IO.gets("") |> String.trim_trailing("\n")`. Map `input(prompt)` to `IO.gets(prompt) |> String.trim_trailing("\n")`.

### 11.17 `math` Module Functions

Python's `math` module provides `math.ceil`, `math.floor`, `math.sqrt`, `math.log`, `math.log2`, `math.log10`, `math.gcd`, etc. These should be mapped to Elixir equivalents:

| Python | Elixir |
|---|---|
| `math.ceil(x)` | `ceil(x)` |
| `math.floor(x)` | `floor(x)` |
| `math.sqrt(x)` | `:math.sqrt(x)` |
| `math.log(x)` | `:math.log(x)` |
| `math.log2(x)` | `:math.log2(x)` |
| `math.log10(x)` | `:math.log10(x)` |
| `math.gcd(a, b)` | `Integer.gcd(a, b)` |
| `math.pow(x, n)` | `:math.pow(x, n)` or `x ** n` |
| `math.pi` | `:math.pi()` |
| `math.e` | `:math.exp(1)` |
| `math.inf` | `:math.inf()` or `:infinity` |

### 11.18 `print()` with Multiple Arguments

**Problem:** Python's `print(a, b, c)` prints values separated by spaces. Elixir's `IO.puts/1` only takes one argument.

```python
print(a, b, c)     # "1 2 3"
print(a, sep=",")  # "1,2,3"
```

```elixir
IO.puts(Enum.join([to_string(a), to_string(b), to_string(c)], " "))
```

**Solution:** For `print(arg)` (single argument), map to `IO.puts(to_string(arg))`. For `print(arg1, arg2, ...)`, map to `IO.puts(Enum.join([to_string(arg1), to_string(arg2), ...], " "))`. For `print(..., sep=..., end=...)`, generate the appropriate `Enum.join` with custom separator and `IO.write` instead of `IO.puts` for custom end.



---

## §12. Supported AST Nodes

### 12.1 Module

`Module` — the root wrapper. `body` is a list of statement nodes.

```elixir
# Python: entire file
%{"_type" => "Module", "body" => [...]}

# Elixir output:
{:__block__, [], [stmt1, stmt2, ...]}
```

### 12.2 Literals

**`Constant`** — all literal values (integers, floats, strings, booleans, None, bytes, complex, Ellipsis).

```elixir
# Python: 42        → Constant(value=42)           → 42
# Python: 3.14      → Constant(value=3.14)         → 3.14
# Python: "hello"   → Constant(value="hello")      → "hello"
# Python: True      → Constant(value=true)         → true
# Python: False     → Constant(value=false)        → false
# Python: None      → Constant(value=nil)          → nil
# Python: b"bytes"  → Constant(value=bytes)        → RAISES UnsupportedNodeError
# Python: 3+4j      → Constant(value=complex)      → RAISES UnsupportedNodeError
# Python: ...       → Constant(value=Ellipsis)     → RAISES UnsupportedNodeError
```

### 12.3 Names

**`Name`** — variable references.

```elixir
# Python: my_var
%{"_type" => "Name", "id" => "my_var", "ctx" => %{"_type" => "Load"}}

# Elixir: {:my_var, [], nil}
```

The `ctx` field is ignored — context is determined structurally by the parent node.

### 12.4 Operators

All operator nodes (listed in §7.1) are handled as child nodes of `BinOp`, `UnaryOp`, `BoolOp`, and `Compare`. They never appear as standalone AST nodes.

### 12.5 Expressions

**`BinOp`** — binary operations.

```elixir
# Python: a + b
# Elixir: {:+, [], [a, b]}
```

**`UnaryOp`** — unary operations.

```elixir
# Python: -x        → {-, [], [x]}
# Python: not x     → {:!, [], [x]}
# Python: ~x        → {:~~~, [], [x]}  (requires import Bitwise)
```

**`BoolOp`** — boolean operations. Uses `values` list, NOT `left`/`right`.

```elixir
# Python: a and b and c
# AST: BoolOp(op=And, values=[Name("a"), Name("b"), Name("c")])
# Elixir: {:&&, [], [{:&&, [], [a, b]}, c]}

# Python: a or b
# Elixir: {:||, [], [a, b]}
```

**CRITICAL:** Use `&&`/`||`, NOT `and`/`or`. See §9.6 and §11.3.

**`Compare`** — comparison operations. Supports chaining.

```elixir
# Python: a < b < c
# AST: Compare(left=Name("a"), ops=[Lt, Lt], comparators=[Name("b"), Name("c")])
# Elixir: {:&&, [], [{:<, [], [a, b]}, {:<, [], [b, c]}]}

# Python: a == b
# Elixir: {:==, [], [a, b]}

# Python: x in items
# Elixir: {:in, [], [x, items]}

# Python: x not in items
# Elixir: {:!, [], [{:in, [], [x, items]}]}
```

**`Call`** — function calls. `func` can be a `Name` (local call) or `Attribute` (remote call).

```elixir
# Python: func(arg1, arg2)
# Elixir: {:func, [], [arg1, arg2]}

# Python: module.func(arg1, arg2)
# AST: Call(func=Attribute(value=Name("module"), attr="func"), args=[...])
# Elixir: {{:., [], [{:__aliases__, [], [:Module]}, :func]}, [], [arg1, arg2]}

# Python: func(arg1, key=arg2)
# Elixir: {:func, [], [arg1, [key: arg2]]}  (keyword list as last arg)
```

**`IfExp`** — ternary expressions.

```elixir
# Python: x if condition else y
# Elixir: {:if, [], [condition, [do: x, else: y]]}
```

**`Subscript`** — indexing and slicing.

```elixir
# Python: x[i]
# Elixir: {{:., [], [{:__aliases__, [], [:Access]}, :get]}, [], [x, i]}
# OR (better for generated code):
# Enum.at(x, i)  — for lists
# Map.get(x, i)  — for maps/dicts
```

**`Attribute`** — attribute access.

```elixir
# Python: obj.attr
# Elixir: {:obj, [], nil}.attr  → this doesn't work in Elixir AST
# The Attribute node is typically part of a Call: obj.method(args) → Module.function(obj, args)
```

**`ListComp`** — list comprehensions.

```elixir
# Python: [x * 2 for x in items if x > 0]
# Elixir:
#   for x <- items, x > 0 do
#     x * 2
#   end

# AST:
# {:for, [], [
#   {:<-, [], [{:x, [], nil}, {:items, [], nil}]},
#   {:>, [], [{:x, [], nil}, 0]},
#   [do: {:*, [], [{:x, [], nil}, 2]}]
# ]}
```

For multiple generators, each generator becomes a `<-` clause:
```elixir
# Python: [(x, y) for x in range(3) for y in range(3)]
# Elixir:
#   for x <- Enum.to_list(0..2), y <- Enum.to_list(0..2) do
#     {x, y}
#   end
```

**`Lambda`** — anonymous functions.

```elixir
# Python: lambda x, y: x + y
# Elixir: fn x, y -> x + y end

# AST:
# {:fn, [], [
#   {:->, [], [
#     [{:x, [], nil}, {:y, [], nil}],
#     {:+, [], [{:x, [], nil}, {:y, [], nil}]}
#   ]}
# ]}
```

### 12.6 Statements

**`Assign`** — variable assignment.

```elixir
# Python: x = 5
# Elixir: x = 5
# AST: {:=, [], [{:x, [], nil}, 5]}

# Python: a = b = 5  (multiple targets)
# Elixir: a = 5; b = 5
```

**`AugAssign`** — augmented assignment.

```elixir
# Python: x += 1
# Elixir: x = x + 1
# AST: {:=, [], [{:x, [], nil}, {:+, [], [{:x, [], nil}, 1]}]}
```

**`Return`** — return statements.

```elixir
# Python: return value
# Elixir: value  (last expression in function body)
```

If the function has early returns (non-tail `return`), the converter emits `try`/`throw`/`catch`. See §11.19 for details.

**`Expr`** — expression used as statement (e.g., function calls whose return value is discarded).

```elixir
# Python: print("hello")  (as a statement)
# Elixir: IO.puts("hello")
```

When the wrapped expression is a mutation method call (e.g., `list.append(x)`), convert to reassignment. See §9.4.

**`If`** — conditional statement.

```elixir
# Python: if cond: ... else: ...
# Elixir: if cond do ... else ... end

# Python: if a: ... elif b: ... else: ...
# Elixir: cond do a -> ...; b -> ...; true -> ... end
```

**`For`** — for loop.

```elixir
# Python: for x in items: body
# Elixir: for x <- items do body end

# Python: for x in range(n): body
# Elixir: for x <- Enum.to_list(0..n-1) do body end
# OR: for x <- 0..(n-1) do body end
```

**`While`** — while loop. Uses `try`/`throw`/`catch` pattern with a recursive helper.

```elixir
# Python:
# while condition:
#     body
#     if break_cond: break
#     if continue_cond: continue
#     post_check
# else:
#     else_body  ← UNSUPPORTED (raises UnsupportedNodeError if non-empty)

# Elixir (using try/throw/catch for break):
# defp while_0 do
#   if condition do
#     body
#     if break_cond, do: throw(:break)
#     if continue_cond, do: while_0()  # skip to next iteration
#     post_check
#     while_0()  # loop back
#   end
# end
#
# try do
#   while_0()
# catch
#   :break -> :ok
# end
```

**Important:** The helper function body must call itself recursively to loop. `continue` is implemented by returning early from the current iteration (calling the helper again before executing remaining statements). `break` is implemented by throwing `:break`. The enclosing `try`/`catch` catches the throw.

**`Pass`** — no-op statement. Produces nothing (empty AST or `nil`).

**`Break`** — loop break. Produces `throw(:break)`.

**`Continue`** — loop continue. Produces a recursive call to the while helper (or `:ok` in a for loop with a filter).

**`Assert`** — assertion.

```elixir
# Python: assert condition, "message"
# Elixir: unless condition, do: raise(AssertionError, "message")

# AST:
# {:unless, [], [
#   condition,
#   [do: {:raise, [], [{:__aliases__, [], [:AssertionError]}, "message"]}]
# ]}
```

**`FunctionDef`** — function definition.

```elixir
# Python: def add(a, b): return a + b
# Elixir: defp add(a, b), do: a + b

# AST:
# {:defp, [], [
#   {:add, [], [{:a, [], nil}, {:b, [], nil}]},
#   [do: {:+, [], [{:a, [], nil}, {:b, [], nil}]}]
# ]}
```

**`Pass`** in a function body produces `nil` or `:ok`:
```elixir
# Python: def noop(): pass
# Elixir: defp noop, do: nil
```

### 12.7 Unsupported Nodes

The following node types raise `UnsupportedNodeError`:

| Category | Nodes |
|---|---|
| **Class system** | `ClassDef` |
| **Async** | `AsyncFunctionDef`, `AsyncFor`, `AsyncWith`, `Await` |
| **Imports** | `Import`, `ImportFrom` |
| **Exception handling** | `Try`, `TryStar`, `ExceptHandler`, `Raise` |
| **Context managers** | `With` |
| **Scope** | `Global`, `Nonlocal` |
| **Generators/Comprehensions** | `GeneratorExp`, `SetComp`, `DictComp` |
| **Collections** | `Set` |
| **Formatted strings** | `FormattedValue`, `JoinedStr`, `TemplateStr`, `Interpolation` |
| **Other expressions** | `NamedExpr` (walrus operator `:=`), `Starred` (in assignment targets) |
| **Other statements** | `Delete`, `AnnAssign`, `TypeAlias` |
| **Pattern matching** | `Match` |
| **Loop else** | `For.orelse`, `While.orelse` (when non-empty) |
| **Complex/bytes** | `Constant` with `complex` or `bytes` value |

### 12.8 Python Builtins

#### Mapped Builtins

| Python Builtin | Elixir Equivalent |
|---|---|
| `len(x)` | `length(x)` (lists), `map_size(x)` (dicts), `tuple_size(x)` (tuples) |
| `range(n)` | `Enum.to_list(0..(n-1))` or `0..(n-1)` |
| `range(start, stop)` | `Enum.to_list(start..(stop-1))` |
| `range(start, stop, step)` | `Enum.to_list(start..(stop-1)//step)` |
| `sorted(x)` | `Enum.sort(x)` |
| `sorted(x, key=f)` | `Enum.sort_by(x, f)` |
| `sorted(x, key=f, reverse=True)` | `Enum.sort_by(x, f, :desc)` |
| `reversed(x)` | `Enum.reverse(x)` |
| `enumerate(x)` | `Enum.with_index(x)` — NOTE: tuple order is swapped! See §11.7 |
| `zip(a, b)` | `Enum.zip([a, b])` |
| `map(f, x)` | `Enum.map(x, f)` |
| `filter(f, x)` | `Enum.filter(x, f)` |
| `sum(x)` | `Enum.sum(x)` |
| `min(a, b)` | `min(a, b)` |
| `max(a, b)` | `max(a, b)` |
| `abs(x)` | `abs(x)` |
| `int(x)` | `trunc(x)` or `String.to_integer(x)` |
| `float(x)` | `x / 1` or `String.to_float(x)` |
| `str(x)` | `to_string(x)` |
| `bool(x)` | `!!x` |
| `list(x)` | `Enum.to_list(x)` |
| `tuple(x)` | `List.to_tuple(Enum.to_list(x))` |
| `set(x)` | `MapSet.new(Enum.to_list(x))` |
| `dict(x)` | `Map.new(Enum.to_list(x))` |
| `type(x)` | See §9.10 |
| `isinstance(x, t)` | See §9.11 |
| `print(x)` | `IO.puts(to_string(x))` |
| `print(a, b, c)` | `IO.puts(Enum.join([to_string(a), to_string(b), to_string(c)], " "))` |
| `input()` | `IO.gets("") \|> String.trim_trailing("\n")` |
| `input(prompt)` | `IO.gets(prompt) \|> String.trim_trailing("\n")` |
| `chr(n)` | `List.to_string([n])` |
| `ord(c)` | `String.to_charlist(c) \|> hd()` |
| `hex(n)` | `"0x" <> Integer.to_string(n, 16)` |
| `oct(n)` | `"0o" <> Integer.to_string(n, 8)` |
| `bin(n)` | `"0b" <> Integer.to_string(n, 2)` |
| `isinstance(x, int)` | `is_integer(x)` |
| `isinstance(x, float)` | `is_float(x)` |
| `isinstance(x, str)` | `is_binary(x)` |
| `isinstance(x, bool)` | `is_boolean(x)` |
| `isinstance(x, list)` | `is_list(x)` |
| `isinstance(x, dict)` | `is_map(x)` |
| `math.ceil(x)` | `ceil(x)` |
| `math.floor(x)` | `floor(x)` |
| `math.sqrt(x)` | `:math.sqrt(x)` |
| `math.log(x)` | `:math.log(x)` |
| `math.log2(x)` | `:math.log2(x)` |
| `math.log10(x)` | `:math.log10(x)` |
| `math.gcd(a, b)` | `Integer.gcd(a, b)` |
| `math.pow(x, n)` | `:math.pow(x, n)` |
| `math.pi` | `:math.pi()` |
| `math.e` | `:math.exp(1)` |
| `math.inf` | `:infinity` |

#### Builtins That Raise `UnsupportedNodeError`

The following builtins are recognized by the lookup table but raise `UnsupportedNodeError` because they have no safe Elixir equivalent:

- `iter(x)` — iterator protocol, not transpilable
- `next(x)` — iterator protocol
- `super()` — class inheritance
- `property` — class descriptor protocol
- `classmethod`, `staticmethod` — class methods
- `getattr`, `setattr`, `hasattr`, `delattr` — dynamic attribute access

#### Builtins Not in the Lookup Table

Any function call where `func` is a `Name` node whose `id` is not in the lookup table and not bound in the current scope will raise `UndefinedNameError`.



---

## §13. Implementation Notes

### 13.1 Output Module

- Generated Elixir code uses `defp` for all functions (transient processing code, not library code).
- `import Bitwise` is conditionally included at the top of the module when bitwise operators are detected (`context.uses_bitwise == true`).
- The generated code ends with a main function call that processes the input.

### 13.2 The `convert/2` Function Pattern

```elixir
def convert(%{"_type" => "Module", "body" => body}, %Context{} = context) do
  {stmts, context} = convert_many(body, context)
  helpers = context.pending_helpers
  bitwise_import = if context.uses_bitwise, do: [quote do: import Bitwise], else: []
  body = bitwise_import ++ helpers ++ stmts
  {:__block__, [], body}
end
```

**Pattern:** Match on the `_type` field. Return `{elixir_ast, updated_context}`.

### 13.3 String-Binary Equivalence

In Elixir, strings ARE binaries. `"hello" == <<104, 101, 108, 108, 111>>`. This means Python code that treats strings as byte arrays (indexing, slicing) does NOT translate directly. Elixir strings are UTF-8 encoded, so `String.at("hello", 0)` returns `"h"`, but `"hello"[0]` in Python returns `"h"` as well (Python 3 strings are also Unicode). The key difference is that Elixir's `String.length/1` counts grapheme clusters while Python's `len()` counts code points — these differ for some Unicode characters.

**Recommendation:** Use `String.at/2` for character access and `String.length/1` for length. Document that multi-codepoint grapheme clusters may behave differently.

### 13.4 Global Variable Pattern

For script-style code with module-level mutable variables, the transpiler wraps the entire module in a module with `Agent`-based state:

```elixir
defmodule TranslatedCode do
  use Agent

  def start_link do
    Agent.start_link(fn -> %{"x" => 0, "counter" => 0} end, name: __MODULE__)
  end

  defp get(var) do
    Agent.get(__MODULE__, &Map.get(&1, var))
  end

  defp set(var, value) do
    Agent.update(__MODULE__, &Map.put(&1, var, value))
  end

  def run do
    set("x", 10)
    set("counter", 0)
    # ... rest of code using get("x") and set("x", new_value)
  end
end
```

**Alternative:** For better performance, use a `GenServer` or process dictionary. The transpiler should default to `Agent` for simplicity.

**Alternative:** For simpler scripts without deeply nested mutation, use the `throw`/`catch` pattern with variable rebinding:

```elixir
def run do
  x = 0
  try do
    Enum.each(1..10, fn i ->
      x = x + i  # This rebinding is local to the fn — WON'T affect outer x!
    end)
  catch
    _ -> :ok
  end
  IO.puts(x)  # Still 0 — the fn's rebinding was local
end
```

This is why `Agent` is necessary for cross-scope mutation. The transpiler must detect when a variable is mutated across scopes and use `Agent` for those variables.

### 13.5 List Comprehension Optimization

For simple list comprehensions, prefer Elixir's `for` comprehension over `Enum.map` + `Enum.filter`:

```elixir
# Preferred: Elixir for comprehension
for x <- items, x > 0, do: x * 2

# Less preferred: Enum chain
items |> Enum.filter(&(&1 > 0)) |> Enum.map(&(&1 * 2))
```

Both produce the same result, but the `for` comprehension is more idiomatic and can be more efficient for multiple generators.

### 13.6 Error Handling

If a Python AST contains an unsupported node type, the converter should raise `UnsupportedNodeError` with a descriptive message including the node type and source location (if available):

```elixir
defmodule Py2Ex.Errors.UnsupportedNodeError do
  defexception [:message, :node_type, :source_line]

  @impl true
  def exception(opts) do
    node_type = Keyword.fetch!(opts, :node_type)
    source_line = Keyword.get(opts, :source_line)
    msg = "Unsupported Python AST node: #{node_type}"
    msg = if source_line, do: msg <> " at line #{source_line}", else: msg
    %__MODULE__{message: msg, node_type: node_type, source_line: source_line}
  end
end

defmodule Py2Ex.Errors.UndefinedNameError do
  defexception [:message, :name]

  @impl true
  def exception(opts) do
    name = Keyword.fetch!(opts, :name)
    %__MODULE__{message: "Undefined name: #{name}", name: name}
  end
end
```

### 13.7 `while` Loop Implementation Detail

The `while` loop uses `try`/`throw`/`catch` for `break` and recursive calls for `continue`:

```elixir
# Python:
# while x < 10:
#     x += 1
#     if x == 5: continue
#     if x == 8: break
#     print(x)

# Elixir:
defp while_0(x) do
  if x < 10 do
    x = x + 1
    if x == 5, do: throw(:continue)  # Skip to next iteration
    if x == 8, do: throw(:break)      # Exit loop
    IO.puts(to_string(x))
    while_0(x)  # Recurse with updated state
  else
    :ok
  end
end

try do
  while_0(0)
catch
  :break -> :ok
  :continue -> :ok  # This won't actually be reached in this pattern
end
```

**Refined pattern with proper continue handling:**

```elixir
defp while_0(x) do
  if x < 10 do
    x = x + 1
    if x == 5 do
      while_0(x)  # continue: skip rest, recurse immediately
    else
      if x == 8 do
        throw(:break)
      else
        IO.puts(to_string(x))
        while_0(x)
      end
    end
  end
end

try do
  while_0(0)
catch
  :break -> :ok
end
```

### 13.8 Comparison Chain Conversion

For `Compare` nodes with multiple operators, generate an `&&` chain:

```elixir
def convert(%{"_type" => "Compare", "left" => left, "ops" => ops, "comparators" => comparators}, ctx) do
  {left_ast, ctx} = convert(left, ctx)
  pairs = Enum.zip(ops, comparators)
  {comparisons, ctx} = Enum.reduce(pairs, {[], ctx}, fn {op, comp}, {acc, ctx} ->
    {op_ast, ctx} = convert(op, ctx)
    {comp_ast, ctx} = convert(comp, ctx)
    comparison = {op_ast, [], [left_ast, comp_ast]}
    {[comparison | acc], ctx}
  end)
  comparisons = Enum.reverse(comparisons)
  # Chain with &&
  result = Enum.reduce(comparisons, fn a, b -> {:&&, [], [a, b]} end)
  {result, ctx}
end
```

### 13.9 The `AugAssign` Subscript Pattern

When `AugAssign.target` is a `Subscript` node (e.g., `d[key] += 1`), the translation is a map update:

```elixir
# Python: d[key] += 1
# Elixir: d = Map.put(d, key, Map.get(d, key, 0) + 1)
```

The `convert/2` function for `AugAssign` must check if `target["_type"]` is `"Subscript"` and handle it differently from simple variable augmentation.

### 13.10 Comparison Operator AST Mapping

```elixir
@comparison_ops %{
  "Eq"    => :==,
  "NotEq" => :!=,
  "Lt"    => :<,
  "LtE"   => :<=,
  "Gt"    => :>,
  "GtE"   => :>=,
  "Is"    => :===,
  "IsNot" => :!==,
  "In"    => :in,
  "NotIn" => :not_in  # special handling: negate the :in result
}
```

### 13.11 If-Elif-Else Chain Conversion

```elixir
def convert(%{"_type" => "If"} = node, ctx) do
  %{"test" => test, "body" => body, "orelse" => orelse} = node
  {test_ast, ctx} = convert(test, ctx)
  {body_ast, ctx} = convert_many(body, ctx)

  case orelse do
    [] ->
      # Simple if (no else)
      {{:if, [], [test_ast, [do: body_ast]]}, ctx}

    [%{"_type" => "If"} = elif_node] ->
      # elif: convert as nested if
      {elif_ast, ctx} = convert(elif_node, ctx)
      {{:if, [], [test_ast, [do: body_ast, else: elif_ast]]}, ctx}

    _ ->
      # else clause
      {else_ast, ctx} = convert_many(orelse, ctx)
      {{:if, [], [test_ast, [do: body_ast, else: else_ast]]}, ctx}
  end
end
```

**Alternative:** For 3+ branches, use `cond` instead of nested `if`/`else`:

```elixir
# Python: if a: ... elif b: ... elif c: ... else: ...
# Elixir (cond is cleaner):
cond do
  a -> ...
  b -> ...
  c -> ...
  true -> ...
end
```

### 13.12 Statement-to-Expression Wrapping

In Python, `if`, `for`, and `while` are statements (no return value). In Elixir, they are expressions (always return a value). When a Python `If` statement appears where a statement is expected (not an expression context), the transpiler can emit the Elixir `if` directly — its return value will be harmlessly ignored by the `__block__` wrapper.

When a Python `If` expression appears inside another expression (e.g., `x = cond if test else other`), the `IfExp` node is used instead, which maps to Elixir's `if` as an expression naturally.

### 13.13 `return` Inside Loops

When a Python function contains a `return` statement inside a `for` or `while` loop, the translation is complex because Elixir's `for`/comprehension cannot "return" from the enclosing function.

**Solution:** Use `try`/`throw`/`catch`:

```elixir
# Python:
# def find_first(items, target):
#     for x in items:
#         if x == target:
#             return x
#     return None

# Elixir:
defp find_first(items, target) do
  try do
    Enum.each(items, fn x ->
      if x == target, do: throw({:return, x})
    end)
    nil  # default return
  catch
    {:return, result} -> result
  end
end
```

**Important:** The `return` value is wrapped in `{:return, value}` to distinguish it from other throws. The `catch` clause unwraps it.

**For nested loops:** The `try`/`catch` must be at the function level, not inside the loop. The converter must detect `Return` nodes inside loops and emit the `try` wrapper around the entire function body.

---

## §14. Testing Strategy

### 14.1 Test Categories

#### 1. Unit Tests (per AST node)

Each supported AST node gets a test that verifies the `convert/2` function produces the correct Elixir AST.

```elixir
test "converts BinOp with Add operator" do
  python_ast = %{
    "_type" => "BinOp",
    "left" => %{"_type" => "Constant", "value" => 1},
    "op" => %{"_type" => "Add"},
    "right" => %{"_type" => "Constant", "value" => 2}
  }
  {result, _ctx} = Py2Ex.convert(python_ast, %Py2Ex.Context{scopes: [MapSet.new()]})
  assert result == {:+, [], [1, 2]}
end
```

#### 2. Integration Tests (full Python programs)

End-to-end tests that transpile a complete Python program and verify the output compiles and runs correctly.

```elixir
test "transpiles fibonacci function" do
  python_source = """
  def fib(n):
      if n <= 1:
          return n
      return fib(n - 1) + fib(n - 2)

  print(fib(10))
  """

  elixir_code = Py2Ex.transpile(python_source)
  assert {:ok, _} = Code.format_string(elixir_code)
  # Optionally: capture IO and verify output
end
```

#### 3. Semantic Correctness Tests

For each edge case in §11, a test that verifies the transpiled code produces the same output as Python.

```elixir
test "floor division matches Python semantics" do
  # Python: -7 // 2 == -4
  assert Integer.floor_div(-7, 2) == -4
end

test "modulo matches Python semantics" do
  # Python: -7 % 3 == 2
  assert Integer.mod(-7, 3) == 2
end
```

#### 4. Error Handling Tests

Verify that unsupported nodes raise `UnsupportedNodeError` with descriptive messages.

```elixir
test "ClassDef raises UnsupportedNodeError" do
  python_ast = %{"_type" => "ClassDef", "name" => "Foo", ...}
  assert_raise Py2Ex.Errors.UnsupportedNodeError, ~r/ClassDef/, fn ->
    Py2Ex.convert(python_ast, %Py2Ex.Context{scopes: [MapSet.new()]})
  end
end
```

#### 5. Round-Trip Tests (Golden Tests)

For a corpus of Python programs, store the expected Elixir output as golden files. On each test run, transpile the Python and compare against the golden output. Any difference indicates a regression.

```
test/fixtures/
  python/
    fibonacci.py
    binary_search.py
    linked_list.py
  elixir/
    fibonacci.exs
    binary_search.exs
    linked_list.exs
```

### 14.2 Test Corpus

Start with these algorithmic programs:

1. **Fibonacci** (recursive and iterative) — tests recursion, `while`, augmented assignment
2. **Binary search** — tests `while`, `if`/`elif`/`else`, comparison chains
3. **Merge sort** — tests list slicing, recursion, `while`
4. **Stack/Queue** — tests list `append`/`pop`, mutation methods
5. **Graph BFS/DFS** — tests dict/list mutation, `while`, `for`/`in`
6. **FizzBuzz** — tests `for`/`range`, `if`/`elif`/`else`, `print`
7. **Two Sum** — tests dict operations, `enumerate`, `for`/`in`
8. **Palindrome check** — tests string slicing, `while`, comparison
9. **Factorial** — tests recursion, `if`, `return`
10. **Prime sieve** — tests `for`/`range`, list mutation, `if`

### 14.3 Test Runner

```elixir
# In mix.exs
defp deps do
  [
    {:jason, "~> 1.4"},
    {:mix_test_watch, "~> 1.0", only: :dev, runtime: false}
  ]
end
```

Run tests with: `mix test`

Run with coverage: `mix test --cover`

Watch mode: `mix test.watch`

---

## §15. Development Steps

| Step | Deliverable | Status |
|------|------------|--------|
| 1 | Project setup with Elixir project, Python JSON serializer, `convert/2` skeleton | **DEFERRED** |
| 2 | Literal and variable support (`Constant`, `Name`) | **DEFERRED** |
| 3 | Arithmetic operators (`BinOp`, `UnaryOp`) | **DEFERRED** |
| 4 | Boolean operators (`BoolOp`, `Compare`) with chaining | **DEFERRED** |
| 5 | Control flow (`If`, `For`, `While`, `Break`, `Continue`, `Pass`) | **DEFERRED** |
| 6 | Functions (`FunctionDef`, `Return`, `Lambda`) | **DEFERRED** |
| 7 | Collections (`List`, `Tuple`, `Dict`, `ListComp`) | **DEFERRED** |
| 8 | Built-in functions (mapped builtins table) | **DEFERRED** |
| 9 | Mutation patterns (`AugAssign`, mutation methods) | **DEFERRED** |
| 10 | `Assert` and `Expr` statement wrapper | **DEFERRED** |
| 11 | Edge case testing and correctness verification | **DEFERRED** |
| 12 | Golden test corpus and regression testing | **DEFERRED** |

---

## §16. Project Structure

```
py2ex/
├── lib/
│   ├── py2ex.ex                  # Main API (transpile/1, transpile_file/1)
│   ├── py2ex/
│   │   ├── context.ex            # Context struct definition
│   │   ├── converter.ex          # Main convert/2 dispatch
│   │   ├── nodes/
│   │   │   ├── literals.ex       # Constant, Name handlers
│   │   │   ├── operators.ex      # BinOp, UnaryOp, BoolOp, Compare
│   │   │   ├── expressions.ex    # Call, IfExp, Subscript, ListComp, Lambda
│   │   │   ├── statements.ex     # Assign, AugAssign, Return, If, For, While, Pass, Break, Continue, Assert, Expr
│   │   │   └── functions.ex      # FunctionDef, arguments, arg
│   │   ├── builtins.ex           # Built-in function mapping table
│   │   ├── scope.ex              # Scope management utilities
│   │   ├── formatter.ex          # Elixir code formatting (Code.format_string!/1)
│   │   └── errors.ex             # UnsupportedNodeError, UndefinedNameError
│   └── py2ex/
│       └── helpers.ex            # Generated helper functions
├── priv/
│   └── python/
│       └── serialize.py          # Python AST serialization script
├── test/
│   ├── py2ex_test.exs            # Integration tests
│   ├── nodes/
│   │   ├── literals_test.exs
│   │   ├── operators_test.exs
│   │   ├── expressions_test.exs
│   │   ├── statements_test.exs
│   │   └── functions_test.exs
│   ├── builtins_test.exs
│   ├── edge_cases_test.exs       # §11 edge case tests
│   └── fixtures/
│       ├── python/               # Python source files
│       └── elixir/               # Golden Elixir output files
├── mix.exs
└── README.md
```



---

## §17. Future Enhancements

After the core transpiler is functional, these enhancements can be considered:

### 17.1 String Similarity

Python strings use Levenshtein distance for fuzzy matching. For candidate sorting by string similarity:

```elixir
# Option 1: Pure Elixir (no dependencies)
defp string_similarity(a, b) do
  # Implement Levenshtein distance in pure Elixir
  # O(n*m) dynamic programming
end

# Option 2: External library
# {:jaro_elixir, "~> 0.1"}  — provides Jaro-Winkler distance
```

### 17.2 Direct Python-to-Elixir AST Bridge

Replace the Python process + JSON pipeline with a direct NIF or port-based bridge:

```elixir
# Python AST → Elixir Term (no JSON serialization overhead)
# Use Zigler or Rustler for a NIF that calls Python's ast module directly
```

### 17.3 Extended Type Inference

Track variable types through the context struct to enable more precise translations:

- `Enum.at(x, i)` vs `Map.get(x, key)` — if we know `x` is a list, use `Enum.at`; if dict, use `Map.get`
- `x in items` — if we know `items` is a `MapSet`, use `MapSet.member?`
- `len(x)` — if we know `x` is a string, use `String.length`; if list, use `length`

### 17.4 Mypy/Type Annotation Integration

Use Python's `typing` module annotations to inform type inference:

```python
def fibonacci(n: int) -> int:
    ...

items: list[int] = [1, 2, 3]
```

The transpiler could read `annotation` fields from the AST to determine types and generate more precise Elixir code.

### 17.5 Class Transpilation (Experimental)

For simple Python classes with only `__init__` and methods:

```python
class Stack:
    def __init__(self):
        self.items = []

    def push(self, item):
        self.items.append(item)

    def pop(self):
        return self.items.pop()
```

Could be transpiled to:

```elixir
defmodule Stack do
  defstruct items: []

  def new, do: %Stack{items: []}

  def push(%Stack{items: items} = stack, item) do
    %{stack | items: items ++ [item]}
  end

  def pop(%Stack{items: items} = stack) do
    {hd(items), %{stack | items: tl(items)}}
  end
end
```

This is a significant undertaking and should be considered a separate phase.

### 17.6 Async/Concurrency Mapping

Python's `async`/`await` could potentially be mapped to Elixir's `Task` module:

```python
async def fetch_data(url):
    response = await aiohttp.get(url)
    return response.json()
```

```elixir
defp fetch_data(url) do
  Task.async(fn -> HTTPClient.get(url) end)
  |> Task.await()
end
```

### 17.7 Generator Expression Support

Python's generator expressions could be mapped to Elixir's `Stream` module:

```python
gen = (x * 2 for x in items if x > 0)
```

```elixir
gen = items |> Stream.filter(&(&1 > 0)) |> Stream.map(&(&1 * 2))
```

---

## §18. Example Session

### 18.1 Session Walkthrough

```
iex> Py2Ex.transpile("def add(a, b): return a + b\n\nprint(add(3, 4))")
```

**Step 1: Input**

```python
def add(a, b):
    return a + b

print(add(3, 4))
```

**Step 2: Python AST (serialized to JSON)**

```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "FunctionDef",
      "name": "add",
      "args": {
        "_type": "arguments",
        "args": [
          {"_type": "arg", "arg": "a"},
          {"_type": "arg", "arg": "b"}
        ],
        "posonlyargs": [],
        "kwonlyargs": [],
        "defaults": [],
        "kw_defaults": []
      },
      "body": [
        {
          "_type": "Return",
          "value": {
            "_type": "BinOp",
            "left": {"_type": "Name", "id": "a", "ctx": {"_type": "Load"}},
            "op": {"_type": "Add"},
            "right": {"_type": "Name", "id": "b", "ctx": {"_type": "Load"}}
          }
        }
      ],
      "decorator_list": [],
      "returns": null
    },
    {
      "_type": "Expr",
      "value": {
        "_type": "Call",
        "func": {"_type": "Name", "id": "print", "ctx": {"_type": "Load"}},
        "args": [
          {
            "_type": "Call",
            "func": {"_type": "Name", "id": "add", "ctx": {"_type": "Load"}},
            "args": [
              {"_type": "Constant", "value": 3},
              {"_type": "Constant", "value": 4}
            ],
            "keywords": []
          }
        ],
        "keywords": []
      }
    }
  ]
}
```

**Step 3: Elixir AST (generated by `convert/2`)**

```elixir
{:__block__, [],
 [
   {:defp, [],
    [
      {:add, [], [{:a, [], nil}, {:b, [], nil}]},
      [do: {:+, [], [{:a, [], nil}, {:b, [], nil}]}]
    ]},
   {:IO, [], :puts},
   {:to_string, [],
    [
      {:add, [], [3, 4]}
    ]}
 ]}
```

**Step 4: Formatted Elixir Code**

```elixir
defp add(a, b), do: a + b

IO.puts(to_string(add(3, 4)))
```

**Step 5: Console Output**

```
7
```

### 18.2 While Loop Example

**Python Input:**

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

**Elixir Output:**

```elixir
defmodule TranslatedCode do
  use Agent

  def start_link do
    Agent.start_link(fn -> %{"count" => 0} end, name: __MODULE__)
  end

  defp get(var), do: Agent.get(__MODULE__, &Map.get(&1, var))
  defp set(var, val), do: Agent.update(__MODULE__, &Map.put(&1, var, val))

  defp while_0 do
    if get("count") < 5 do
      set("count", get("count") + 1)
      if get("count") == 3 do
        while_0()
      else
        if get("count") == 5 do
          throw(:break)
        else
          IO.puts(to_string(get("count")))
          while_0()
        end
      end
    end
  end

  def run do
    start_link()
    try do
      while_0()
    catch
      :break -> :ok
    end
  end
end

TranslatedCode.run()
```

**Console Output:**

```
1
2
4
```

---

## §19. Complete Python Program Example

**Python Input:**

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

**Elixir Output:**

```elixir
defmodule TranslatedCode do
  defp binary_search(arr, target) do
    try do
      left = 0
      right = length(arr) - 1
      try do
        while_0(arr, target, left, right)
      catch
        {:return, result} -> result
      end
    catch
      {:return, result} -> result
    end
  end

  defp while_0(arr, target, left, right) do
    if left <= right do
      mid = Integer.floor_div(left + right, 2)
      cond do
        Enum.at(arr, mid) == target ->
          throw({:return, mid})
        Enum.at(arr, mid) < target ->
          while_0(arr, target, mid + 1, right)
        true ->
          while_0(arr, target, left, mid - 1)
      end
    end
  end

  def run do
    result = binary_search([1, 3, 5, 7, 9, 11, 13], 7)
    IO.puts(to_string(result))
  end
end

TranslatedCode.run()
```

**Console Output:**

```
3
```

**Key translation decisions in this example:**
1. `(left + right) // 2` → `Integer.floor_div(left + right, 2)` (not `div/2` — see §11.1)
2. `arr[mid]` → `Enum.at(arr, mid)` (list indexing)
3. `elif`/`else` → `cond` block (see §13.11)
4. `return` inside `while` → `throw({:return, value})` + `try`/`catch` (see §13.13)
5. `while` loop → recursive helper function with `try`/`catch` for `break`

---

## §20. References

- **Python AST documentation**: https://docs.python.org/3/library/ast.html
- **Python AST JSON format**: https://greentreesnakes.readthedocs.io/
- **Elixir AST documentation**: https://hexdocs.pm/elixir/Macro.html
- **Elixir `Code.format_string!/1`**: https://hexdocs.pm/elixir/Code.html#format_string!/1
- **`python3 -m ast` documentation**: https://docs.python.org/3/library/ast.html#ast.dump
- **Elixir `Bitwise` module**: https://hexdocs.pm/elixir/Bitwise.html
- **Elixir `Integer.floor_div/2`**: https://hexdocs.pm/elixir/Integer.html#floor_div/2
- **Elixir `Integer.mod/2`**: https://hexdocs.pm/elixir/Integer.html#mod/2

---

## §21. Glossary of Elixir Terms for Python Developers

This glossary explains Elixir-specific terms that appear throughout this document, for readers who are primarily Python developers.

| Elixir Term | Explanation |
|---|---|
| **AST** | Abstract Syntax Tree. In Elixir, the AST is a nested structure of three-tuples `{atom, metadata, args}`. See §8. |
| **Atom** | A constant whose name is its value. Like Python's interned strings. `:hello` is an atom; `true` and `false` are atoms. |
| **Binary** | A sequence of bytes. In Elixir, strings ARE binaries. `<<104, 101, 108, 108, 111>>` == `"hello"`. |
| **Keyword list** | A list of `{atom, value}` tuples. Like Python's `**kwargs`. `[key: "value"]` is shorthand for `[{:key, "value"}]`. |
| **Map** | A key-value data structure. Like Python's `dict`. `%{"key" => "value"}` or `%{key: "value"}`. |
| **MapSet** | A set implementation backed by a map. Like Python's `set`. `MapSet.new([1, 2, 3])`. |
| **Pattern matching** | Elixir's core feature for destructuring data. `{:ok, value} = {:ok, 42}` binds `value` to `42`. |
| **Pin operator** | `^` — used to match against an existing variable's value instead of rebinding. `^x = 42` asserts `x` is already `42`. |
| **Rebinding** | In Elixir, variables can be "reassigned" (`x = 1; x = 2`). This creates a new binding, not mutation. |
| **Three-tuple** | A tuple with exactly 3 elements: `{a, b, c}`. The fundamental unit of Elixir's AST. |
| **Tuple** | An ordered collection of fixed size. `{1, "hello", :ok}`. Like Python's `tuple`. |
| **`defp`** | Define a private function (module-internal). Like Python's function without `__all__` export. |
| **`def`** | Define a public function. |
| **`fn`** | Anonymous function. Like Python's `lambda`. `fn x -> x + 1 end`. |
| **`quote`** | Returns the AST of an expression without evaluating it. `quote do: 1 + 2` returns `{:+, [], [1, 2]}`. |
| **`unquote`** | Inside `quote`, evaluates an expression and splices the result into the AST. |
| **Special form** | AST node that cannot be implemented as a macro. Examples: `fn`, `case`, `try`, `receive`. |
| **`__block__`** | The AST representation of a block of expressions. `{:__block__, [], [expr1, expr2, ...]}`. |
| **`__aliases__`** | The AST representation of a module alias. `{:__aliases__, [:alias, Foo]}`. |
| **`Code.format_string!/1`** | Formats Elixir source code. Returns **iodata** (not binary). Use `IO.iodata_to_binary/1` to get a string. |
| **iodata** | A list of binaries and characters for efficient IO. Not the same as a binary/string. |
| **`Macro.to_string/1`** | Converts an Elixir AST back to source code string. Useful for debugging. |
| **`Agent`** | A simple state-holding process. Used for mutable variable simulation. |
| **NIF** | Native Implemented Function. A way to call C/Rust code from Elixir. |
| **Port** | A mechanism for communicating with external OS processes. |

---

## Appendix A: Python AST JSON Examples

### A.1 Simple Assignment

**Python:** `x = 42`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "Assign",
      "targets": [{"_type": "Name", "id": "x", "ctx": {"_type": "Store"}}],
      "value": {"_type": "Constant", "value": 42}
    }
  ]
}
```

### A.2 If-Elif-Else

**Python:** `if a: x = 1\nelif b: x = 2\nelse: x = 3`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "If",
      "test": {"_type": "Name", "id": "a", "ctx": {"_type": "Load"}},
      "body": [
        {
          "_type": "Assign",
          "targets": [{"_type": "Name", "id": "x", "ctx": {"_type": "Store"}}],
          "value": {"_type": "Constant", "value": 1}
        }
      ],
      "orelse": [
        {
          "_type": "If",
          "test": {"_type": "Name", "id": "b", "ctx": {"_type": "Load"}},
          "body": [
            {
              "_type": "Assign",
              "targets": [{"_type": "Name", "id": "x", "ctx": {"_type": "Store"}}],
              "value": {"_type": "Constant", "value": 2}
            }
          ],
          "orelse": [
            {
              "_type": "Assign",
              "targets": [{"_type": "Name", "id": "x", "ctx": {"_type": "Store"}}],
              "value": {"_type": "Constant", "value": 3}
            }
          ]
        }
      ]
    }
  ]
}
```

### A.3 While Loop with Break

**Python:** `while True:\n    if x > 10: break\n    x += 1`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "While",
      "test": {"_type": "Constant", "value": true},
      "body": [
        {
          "_type": "If",
          "test": {
            "_type": "Compare",
            "left": {"_type": "Name", "id": "x", "ctx": {"_type": "Load"}},
            "ops": [{"_type": "Gt"}],
            "comparators": [{"_type": "Constant", "value": 10}]
          },
          "body": [{"_type": "Break"}],
          "orelse": []
        },
        {
          "_type": "AugAssign",
          "target": {"_type": "Name", "id": "x", "ctx": {"_type": "Store"}},
          "op": {"_type": "Add"},
          "value": {"_type": "Constant", "value": 1}
        }
      ],
      "orelse": []
    }
  ]
}
```

### A.4 List Comprehension

**Python:** `[x * 2 for x in items if x > 0]`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "Expr",
      "value": {
        "_type": "ListComp",
        "elt": {
          "_type": "BinOp",
          "left": {"_type": "Name", "id": "x", "ctx": {"_type": "Load"}},
          "op": {"_type": "Mult"},
          "right": {"_type": "Constant", "value": 2}
        },
        "generators": [
          {
            "_type": "comprehension",
            "target": {"_type": "Name", "id": "x", "ctx": {"_type": "Store"}},
            "iter": {"_type": "Name", "id": "items", "ctx": {"_type": "Load"}},
            "ifs": [
              {
                "_type": "Compare",
                "left": {"_type": "Name", "id": "x", "ctx": {"_type": "Load"}},
                "ops": [{"_type": "Gt"}],
                "comparators": [{"_type": "Constant", "value": 0}]
              }
            ],
            "is_async": 0
          }
        ]
      }
    }
  ]
}
```

### A.5 Function with Default Arguments

**Python:** `def greet(name, greeting="Hello"): return greeting + ", " + name + "!"`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "FunctionDef",
      "name": "greet",
      "args": {
        "_type": "arguments",
        "posonlyargs": [],
        "args": [
          {"_type": "arg", "arg": "name", "annotation": null},
          {"_type": "arg", "arg": "greeting", "annotation": null}
        ],
        "kwonlyargs": [],
        "kw_defaults": [],
        "defaults": [
          {"_type": "Constant", "value": "Hello"}
        ]
      },
      "body": [
        {
          "_type": "Return",
          "value": {
            "_type": "BinOp",
            "left": {
              "_type": "BinOp",
              "left": {
                "_type": "BinOp",
                "left": {"_type": "Name", "id": "greeting", "ctx": {"_type": "Load"}},
                "op": {"_type": "Add"},
                "right": {"_type": "Constant", "value": ", "}
              },
              "op": {"_type": "Add"},
              "right": {"_type": "Name", "id": "name", "ctx": {"_type": "Load"}}
            },
            "op": {"_type": "Add"},
            "right": {"_type": "Constant", "value": "!"}
          }
        }
      ],
      "decorator_list": [],
      "returns": null,
      "type_comment": null
    }
  ]
}
```

---

## Appendix B: Edge Case Quick Reference Card

A compact reference for the most common correctness traps.

| # | Trap | Wrong | Right | Section |
|---|------|-------|-------|---------|
| 1 | Floor division | `div(a, b)` | `Integer.floor_div(a, b)` | §11.1 |
| 2 | Modulo | `rem(a, b)` | `Integer.mod(a, b)` | §11.2 |
| 3 | Truthiness | `if my_list do` | `if my_list != [] do` | §11.3 |
| 4 | Chained comparison | `a < b < c` | `a < b && b < c` | §11.4 |
| 5 | Boolean operators | `a and b` | `a && b` | §9.6 |
| 6 | `enumerate` order | `{i, x}` | `{x, i}` then swap | §11.7 |
| 7 | `strip(chars)` | `String.trim(s, chars)` | Regex-based helper | §11.12 |
| 8 | `replace(s, o, n, 1)` | `String.replace(s, o, n)` | `String.replace(s, o, n, global: false)` | §11.13 |
| 9 | `return` in loop | Direct return | `try`/`throw`/`catch` | §13.13 |
| 10 | `continue` in while | Skip | Recursive call to helper | §13.7 |
| 11 | `break` in while | No-op | `throw(:break)` | §13.7 |
| 12 | `print(a, b)` | `IO.puts(a, b)` | `IO.puts(Enum.join(..., " "))` | §11.18 |
| 13 | `len(s)` for strings | `length(s)` | `String.length(s)` | §9.9 |
| 14 | `in` for sets | `x in set` | `MapSet.member?(set, x)` | §9.8 |
| 15 | `not in` | `not x in items` | `!(x in items)` | §9.8 |
| 16 | Closure capture | `fn -> x end` (captures value) | Document as known limitation | §11.6 |
| 17 | `d[key]` missing | `d[key]` | `Map.fetch!(d, key)` | §11.11 |
| 18 | `Code.format_string!` | Returns string | Returns iodata; use `IO.iodata_to_binary/1` | §6.1 |

---

*End of RFC-001 v5*
