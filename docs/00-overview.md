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

The library exposes two entry points:

- **`Pylixir.to_source/1`** — the core API. Accepts a Python AST map (already decoded from JSON), returns an Elixir source code string. This is a pure function with no external dependencies.

- **`Pylixir.transpile/1`** — a convenience wrapper for interactive use and testing. Accepts a Python source code string, shells out to `python3` to parse it via `ast.parse()` and serialize to JSON, decodes the JSON, then calls `to_source/1` on the result. **Requires Python 3.8+ on the system PATH.** Production callers should pre-parse their ASTs and use `to_source/1` directly.

```elixir
# Core API — no Python dependency
Pylixir.to_source(%{"_type" => "Module", "body" => [...]})
# => "defmodule TranslatedCode do ... end\n\nTranslatedCode.run()"

# Convenience wrapper — requires Python 3.8+ on PATH
Pylixir.transpile("def add(a, b): return a + b\nprint(add(3, 4))")
# => "defmodule TranslatedCode do ... end\n\nTranslatedCode.run()"
```

### 1.3 What "Working, Not Idiomatic" Means

The output is **working, not idiomatic** Elixir. The goal is correctness — code that compiles and produces the same results as the Python original. It will not be pretty. It will use `Enum.reduce` where a human would write `Enum.map`. It will generate helper functions for `while` loops. It will produce `{result}` tuple accumulators for single-variable loops. It is a mechanical translation, not a stylistic one.

Performance characteristics may differ from the Python original (e.g., list indexing with `Enum.at/2` is O(n) rather than O(1)). This is acceptable — the goal is behavioral correctness, not algorithmic complexity preservation.

### 1.4 Target Use Case

This library targets **self-contained algorithmic code**: the kind of Python you'd find in coding challenges, algorithmic puzzles, and small utility functions. Typical translatable code includes sorting algorithms, dynamic programming solutions, graph traversals, mathematical computations, string manipulation functions, and similar standalone logic.

### 1.5 Design Philosophy

1. **Correctness over elegance.** Every translated construct must produce the same result as the Python original, including edge cases (negative modulo, floor division, truthiness).
2. **Explicit over implicit.** When Python and Elixir semantics diverge, the generated code makes the divergence explicit (e.g., `Integer.floor_div/2` instead of `div/2`).
3. **Runtime dispatch over static type inference.** When the correct translation depends on operand type (e.g., `+` for numbers vs strings, `not` with Python vs Elixir truthiness), the generated code uses runtime-dispatching helpers (`py_add/2`, `truthy?/1`) rather than attempting compile-time type inference. This trades some performance for correctness and implementation simplicity.
4. **Fail loudly on unsupported constructs.** Never produce silent wrong code. Raise `UnsupportedNodeError` for anything not handled.
5. **No Python dependency at runtime.** The core `to_source/1` API receives pre-parsed ASTs as Elixir maps. Python is used only offline to produce the JSON (or via the optional `transpile/1` convenience wrapper).

---
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
    → Pylixir.to_source/1
    → Elixir source code string
```

The optional `Pylixir.transpile/1` wraps the entire pipeline into a single call, shelling out to Python for steps 1–3.

### 3.2 Why?

This library exists to bridge the gap between Python's algorithmic ecosystem and Elixir's runtime. Many algorithmic problems, competitive programming solutions, and reference implementations exist in Python. Being able to mechanically translate them to working Elixir code enables:

- Porting algorithmic solutions without manual rewriting
- Verifying Elixir implementations against Python references
- Generating Elixir test fixtures from Python implementations
- Educational tooling for learning Elixir by translating familiar Python

### 3.3 What Success Looks Like

A user takes a Python function (e.g., a binary search implementation), runs it through `ast.parse()` + `ast2json`, feeds the resulting JSON to `Pylixir.to_source/1`, and gets Elixir code that:

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
| **I/O** | `open()`, `read()`, `write()`, file operations | Beyond algorithmic translation scope |
| **Exceptions** | `try`/`except`/`finally`, `raise` with custom types, exception chaining | While `try`/`rescue` exists in Elixir, mapping Python's exception hierarchy is a separate project |
| **Generators** | `yield`, `yield from`, generator expressions, `send()`, `throw()` on generators | No direct Elixir equivalent; would require coroutine emulation |
| **Context managers** | `with` statement, `__enter__`/`__exit__` | No direct Elixir equivalent |
| **Metaclasses** | `type()`, `__metaclass__`, `__new__` | Deep Python internals with no Elixir parallel |
| **Standard library** | `os`, `sys`, `json`, `re`, `collections`, `itertools`, etc. | Would need per-module mapping; only basic builtins are supported |
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
- **Slicing:** `x[1:3]`, `x[::-1]`, `x[::2]` and similar slice expressions
- **Dict iteration:** `dict.items()`, `dict.keys()`, `dict.values()`
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
