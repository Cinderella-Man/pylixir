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
# Python: a + b  (numbers)
# Elixir: py_add(a, b)  — runtime dispatch, see §11.19

# Python: "hello" + " world"  (both operands are string literals — can optimize)
# Elixir: {:<>, [], ["hello", " world"]}

# Python: a * b  (could be string/list repetition)
# Elixir: py_mult(a, b)  — runtime dispatch, see §11.20
```

**`UnaryOp`** — unary operations.

```elixir
# Python: -x        → {-, [], [x]}
# Python: not x     → {:!, [], [truthy?(x)]}  — see §11.3
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

**CRITICAL:** Use `&&`/`||`, NOT `and`/`or`. See §9.7 and §11.3.

**`Compare`** — comparison operations. Supports chaining.

```elixir
# Python: a < b < c
# AST: Compare(left=Name("a"), ops=[Lt, Lt], comparators=[Name("b"), Name("c")])
# Elixir: {:&&, [], [{:<, [], [a, b]}, {:<, [], [b, c]}]}

# Python: a == b
# Elixir: {:==, [], [a, b]}

# Python: x in items
# Elixir: py_in(x, items)  — runtime dispatch, see §9.9

# Python: x not in items
# Elixir: !py_in(x, items)

# Python: x is None
# Elixir: {:==, [], [x, nil]}
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
# Python: x[i]  (simple index — list)
# Elixir: Enum.at(x, i)

# Python: d[key]  (dict access)
# Elixir: Map.fetch!(d, key)  — NOT Map.get, to match Python's KeyError behavior

# Python: x[1:3]  (slice — Subscript.slice is a Slice node)
# Elixir: Enum.slice(x, 1..2)
# See §11.21 for full slice translation table
```

**Note on `Subscript` dispatch:** When the `Subscript.slice` is a `Slice` node, always use the slice translation table (§11.21). When it is a simple expression (integer index or key), the converter uses `Enum.at/2` for lists, `String.at/2` for strings, and `Map.fetch!/2` for dicts. Since the transpiler does not track types, it uses the runtime-dispatching helper `py_getitem/2` (see §13.20 for the canonical definition).

**Note on MapSet:** `MapSet` is a struct (map), so the `is_map` clause in `py_getitem` would match MapSets. This is acceptable because `MapSet` does not support subscript access in Python (sets are not subscriptable), so this case should not arise in valid translated code.

**`Attribute`** — attribute access.

```elixir
# Python: obj.attr
# The Attribute node is typically part of a Call: obj.method(args) → Module.function(obj, args)
# For dict methods: d.items() → Map.to_list(d), d.keys() → Map.keys(d), d.values() → Map.values(d)
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
# Elixir: temp = 5; a = temp; b = temp
# (For simple literals, can be simplified to: a = 5; b = 5)

# Python: a, b = b, a  (tuple unpacking / swap)
# Elixir: {a, b} = {b, a}
# Right side is fully evaluated before pattern match, so swap works correctly.
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

If the function has early returns (non-tail `return`), the converter emits `try`/`throw`/`catch`. See §13.13 for details.

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

The translation depends on whether the loop body mutates variables defined outside the loop. See §13.4 for the full accumulator detection strategy.

```elixir
# Case 1: No external mutation (pure side effects like print, or building a new list)
# Python: for x in items: print(x)
# Elixir: Enum.each(items, fn x -> IO.puts(to_string(x)) end)

# Case 2: External mutation (loop body modifies variables from outer scope)
# Python:
#   total = 0
#   for x in items:
#       total += x
# Elixir:
#   total = Enum.reduce(items, 0, fn x, total -> total + x end)

# Case 3: Iterating with range
# Python: for x in range(n): body
# Elixir: Enum.reduce(0..(n-1), acc, fn x, acc -> ... end)
```

**`While`** — while loop. Uses recursive helper function with `try`/`throw`/`catch` for break. The helper function returns its state tuple so the caller can use updated values. See §13.7.

**`Pass`** — no-op statement. Produces nothing (empty AST or `nil`).

**`Break`** — loop break. Produces `throw(:break)` (in while loops) or `throw({:break, acc})` (in for/reduce loops).

**`Continue`** — loop continue. In `while` loops, produces a recursive call to the while helper (skipping the remaining body). In `for` loops via `Enum.reduce`, produces `acc` (returns accumulator unchanged, skipping the rest of the iteration). See §13.18.

**`Assert`** — assertion.

```elixir
# Python: assert condition, "message"
# Elixir: unless condition, do: raise(RuntimeError, "message")

# AST:
# {:unless, [], [
#   condition,
#   [do: {:raise, [], [{:__aliases__, [], [:RuntimeError]}, "message"]}]
# ]}
```

**Note:** Python's `AssertionError` is mapped to Elixir's built-in `RuntimeError` for simplicity. Defining a custom `AssertionError` exception module is unnecessary for algorithmic code.

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
| **Imports** | `Import`, `ImportFrom` — **exception:** `import math` is silently ignored (see §13.6.1) |
| **Exception handling** | `Try`, `TryStar`, `ExceptHandler`, `Raise` |
| **Context managers** | `With` |
| **Scope** | `Global`, `Nonlocal` |
| **Generators/Comprehensions** | `GeneratorExp`, `SetComp`, `DictComp` |
| **Collections** | `Set` |
| **Formatted strings** | `FormattedValue`, `JoinedStr`, `TemplateStr`, `Interpolation` |
| **Other expressions** | `NamedExpr` (walrus operator `:=`), `Starred` (in assignment targets) |
| **Other statements** | `Delete`, `AnnAssign`, `TypeAlias` |
| **Pattern matching** | `Match`, `match_case` |
| **Operators** | `MatMult` (matrix multiplication) |
| **Loop else** | `For.orelse`, `While.orelse` (when non-empty) |
| **Complex/bytes** | `Constant` with `complex` or `bytes` value |
| **Math constants** | `math.inf`, `math.nan` (no safe numeric equivalent) |

### 12.8 Python Builtins

#### Mapped Builtins

| Python Builtin | Elixir Equivalent |
|---|---|
| `len(x)` | `py_len(x)` — runtime dispatch (see §9.10) |
| `range(n)` | `0..(n-1)//1` |
| `range(start, stop)` | `start..(stop-1)//1` |
| `range(start, stop, step)` | See §11.22 for step-direction-dependent formula |
| `sorted(x)` | `Enum.sort(x)` |
| `sorted(x, reverse=True)` | `Enum.sort(x, :desc)` |
| `sorted(x, key=f)` | `Enum.sort_by(x, f)` |
| `sorted(x, key=f, reverse=True)` | `Enum.sort_by(x, f, :desc)` |

**`sorted` keyword argument detection:** The `key` and `reverse` arguments appear as `keyword` nodes in the AST's `Call.keywords` list. The converter must inspect `keywords` for entries with `arg: "key"` and `arg: "reverse"`. When `reverse` is present and its `value` is `Constant(value=true)`, use `:desc`. When `key` is present, switch from `Enum.sort` to `Enum.sort_by`. When both are present, use `Enum.sort_by(x, f, :desc)`.

| `reversed(x)` | `Enum.reverse(x)` |
| `enumerate(x)` | `Enum.with_index(x)` — NOTE: tuple order is swapped! See §11.7 |
| `enumerate(x, start)` | `Enum.with_index(x, start)` — NOTE: tuple order is still swapped |
| `zip(a, b)` | `Enum.zip(a, b)` |
| `zip(a, b, c, ...)` | `Enum.zip([a, b, c, ...])` (3+ args use the list form) |
| `map(f, x)` | `Enum.map(x, f)` |
| `filter(f, x)` | `Enum.filter(x, f)` |
| `sum(x)` | `Enum.sum(x)` |
| `min(a, b)` | `min(a, b)` |
| `min(iterable)` | `Enum.min(iterable)` |
| `max(a, b)` | `max(a, b)` |
| `max(iterable)` | `Enum.max(iterable)` |
| `abs(x)` | `abs(x)` |
| `int()` | `0` (no arguments — Python returns 0) |
| `int(x)` | `py_int(x)` — runtime dispatch (see helpers in §13.20) |
| `int(x, base)` | `String.to_integer(String.trim(x), base)` |
| `float()` | `0.0` (no arguments — Python returns 0.0) |
| `float(x)` | `py_float(x)` — runtime dispatch (see helpers in §13.20) |
| `str(x)` | `py_str(x)` — NOT `to_string(x)` (see §11.18 for True/False/None divergence) |
| `bool(x)` | `truthy?(x)` (local helper — see §13.20) |
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
| `isinstance(x, int)` | `is_integer(x)` |
| `isinstance(x, float)` | `is_float(x)` |
| `isinstance(x, str)` | `is_binary(x)` |
| `isinstance(x, bool)` | `is_boolean(x)` |
| `isinstance(x, list)` | `is_list(x)` |
| `isinstance(x, dict)` | `is_map(x)` |
| `isinstance(x, (int, float))` | `is_number(x)` |

**`isinstance` with type tuples:** Python's `isinstance(x, (int, float))` is mapped to `is_number(x)` as a special case. Other tuple forms like `isinstance(x, (int, str))` would need `is_integer(x) or is_binary(x)`. For the MVP, only the `(int, float)` → `is_number` mapping is supported. Other tuple forms raise `UnsupportedNodeError`.

| `print()` | `IO.puts("")` (no arguments — prints empty line) |
| `print(x)` | `IO.puts(py_str(x))` — use `py_str`, NOT `to_string` (see §11.18) |
| `print(a, b, c)` | `IO.puts(Enum.join([py_str(a), py_str(b), py_str(c)], " "))` |

**`print` with `sep` and `end` keywords:** Python's `print(a, b, sep=",")` uses a custom separator, and `print(a, end="")` suppresses the trailing newline. For `sep=...`, replace `" "` with the custom separator in the `Enum.join` call. For `end=...`, use `IO.write` instead of `IO.puts` and append the custom ending. For the MVP, `sep` is straightforward to implement; `end` requires switching from `IO.puts` to `IO.write(Enum.join(...) <> end_str)`. Both are detected via `keyword` nodes in `Call.keywords` (same mechanism as `sorted`'s `key`/`reverse`).

| `input()` | `IO.gets("") \|> String.trim_trailing("\n")` |
| `input(prompt)` | `IO.gets(prompt) \|> String.trim_trailing("\n")` |
| `chr(n)` | `List.to_string([n])` |
| `ord(c)` | `String.to_charlist(c) \|> hd()` |
| `hex(n)` | `py_hex(n)` — helper handles negative numbers and lowercase (see §11.15) |
| `oct(n)` | `py_oct(n)` — helper handles negative numbers (see §11.15) |
| `bin(n)` | `py_bin(n)` — helper handles negative numbers (see §11.15) |
| `math.ceil(x)` | `ceil(x)` |
| `math.floor(x)` | `floor(x)` |
| `math.sqrt(x)` | `:math.sqrt(x)` |
| `math.log(x)` | `:math.log(x)` |
| `math.log2(x)` | `:math.log2(x)` |
| `math.log10(x)` | `:math.log10(x)` |
| `math.gcd(a, b)` | `Integer.gcd(a, b)` |
| `math.gcd(a, b, c, ...)` | `Enum.reduce([a, b, c, ...], &Integer.gcd/2)` (Python 3.9+) |
| `math.pow(x, n)` | `:math.pow(x, n)` |
| `math.pi` | `:math.pi()` |
| `math.e` | `:math.exp(1)` |
| `math.inf` | **RAISES UnsupportedNodeError** — no safe Elixir equivalent (see §11.17) |
| `round(x)` | `round(x)` — **WARNING: rounding mode differs** (see §11.25). Python uses banker's rounding (half-to-even), Elixir uses half-away-from-zero. For exact semantics, use `py_round(x)` helper. |
| `round(x, n)` | `Float.round(x, n)` — same rounding mode caveat as `round(x)` |
| `divmod(a, b)` | `{Integer.floor_div(a, b), Integer.mod(a, b)}` — returns a tuple of (quotient, remainder) using floored division |
| `any(x)` | `Enum.any?(x, &truthy?/1)` — **NOT** `Enum.any?(x)`, which uses Elixir truthiness (see §11.3) |
| `all(x)` | `Enum.all?(x, &truthy?/1)` — **NOT** `Enum.all?(x)`, which uses Elixir truthiness (see §11.3) |
| `abs(x)` | `py_abs(x)` — wraps `abs/1` with boolean handling (see §11.26). For code known to be numeric-only, `abs(x)` directly is fine. |

**`min`/`max` dispatch rule:** Python's `min` and `max` accept either two arguments (`min(a, b)`) or a single iterable (`min([1, 2, 3])`). The converter must check argument count: one argument → `Enum.min/1` or `Enum.max/1`; two or more arguments → Elixir's built-in `min/2` or `max/2`.

#### String Methods (Non-Mutating)

These are method calls on string objects. See §9.5.1 for the full table and implementation details.

#### Dictionary Methods (Non-Mutating)

These are called as expressions (not statements) and return values. See §9.5 for the full table including mutation methods.

#### Builtins That Raise `UnsupportedNodeError`

The following builtins are recognized by the lookup table but raise `UnsupportedNodeError` because they have no safe Elixir equivalent:

- `iter(x)` — iterator protocol, not transpilable
- `next(x)` — iterator protocol
- `super()` — class inheritance
- `property` — class descriptor protocol
- `classmethod`, `staticmethod` — class methods
- `getattr`, `setattr`, `hasattr`, `delattr` — dynamic attribute access

#### Unknown Function Calls

Any function call where `func` is a `Name` node whose `id` is not in the lookup table is emitted as-is (a local function call). The converter does a pre-pass over `Module.body` to collect all `FunctionDef` names (see §13.20), so functions defined later in the file are recognized. If the name is neither a builtin nor a defined function, the call is still emitted — the Elixir compiler will catch any truly undefined function at compile time. This avoids false positives from overly aggressive error checking.
