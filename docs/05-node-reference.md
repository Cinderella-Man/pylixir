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

