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
| `x **= n` | `AugAssign(target=Name("x"), op=Pow, value=n)` | `x = :math.pow(x, n)` (see §11.22) |
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
| `my_list.pop()` | `Expr(value=Call(Attribute(Name("my_list"), "pop"), []))` | `my_list = List.delete_at(my_list, -1)` |
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

### 9.5 Dictionary Iteration Methods

Python dicts have methods that return views over their contents. These are commonly used as iterators in `for` loops:

| Python Method | Elixir Translation |
|---|---|
| `my_dict.items()` | `Map.to_list(my_dict)` (returns `[{key, value}, ...]`) |
| `my_dict.keys()` | `Map.keys(my_dict)` |
| `my_dict.values()` | `Map.values(my_dict)` |

**Note on `items()` tuple order:** Python's `dict.items()` yields `(key, value)` tuples. Elixir's `Map.to_list/1` also returns `{key, value}` tuples. The order matches, so no swapping is needed (unlike `enumerate`).

### 9.6 `del` and `pop` — List Mutation Behavior

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

**`pop()` with no argument:** Python's `my_list.pop()` (no argument) pops the last element. The same two-part pattern applies:

```python
removed = my_list.pop()
```

```elixir
removed = Enum.at(my_list, -1)
my_list = List.delete_at(my_list, -1)
```

### 9.7 Elixir's `&&`/`||`/`!` vs `and`/`or`/`not`

When converting Python's `and`/`or`/`not` to Elixir, use `&&`/`||`/`!`, NOT `and`/`or`/`not`.

**Why:** Elixir's `and`/`or`/`not` are strict boolean operators — they raise `BadBooleanError` on non-boolean values. Python's boolean operators accept any value. Since Python algorithmic code frequently uses truthiness checks on integers and strings (`if my_list:` meaning "if not empty"), the strict operators would crash.

| Python | Elixir | Elixir strict (WRONG) |
|---|---|---|
| `a and b` | `a && b` | `a and b` ← crashes if `a` is not boolean |
| `a or b` | `a \|\| b` | `a or b` ← crashes if `a` is not boolean |
| `not a` | `!a` | `not a` ← crashes if `a` is not boolean |

### 9.8 `Enum.at/2` for Index Access

Python uses `my_list[i]` for indexing. Elixir uses `Enum.at(list, index)`. However, `Enum.at/2` does **not** support assignment (Elixir is immutable). For mutation at an index:

```python
my_list[i] = new_value
```

```elixir
my_list = List.replace_at(my_list, i, new_value)
```

### 9.9 The `in` Operator

Python's `in` operator checks membership in any collection. Since the transpiler does not perform type inference (see §1.5), it uses a runtime-dispatching helper for `in` checks where the collection type is unknown:

```elixir
defp py_in(elem, collection) when is_list(collection), do: elem in collection
defp py_in(elem, collection) when is_map(collection), do: Map.has_key?(collection, elem)
defp py_in(elem, collection) when is_binary(collection), do: String.contains?(collection, elem)
defp py_in(elem, %MapSet{} = collection), do: MapSet.member?(collection, elem)
```

When the collection is a literal list or range, the converter can emit `x in collection` directly. Otherwise, emit `py_in(x, collection)`.

**Note:** `not in` is a single comparison operator `NotIn` in the AST — it is NOT `Not` wrapping `In`. This is because `not in` is a Python keyword pair, not the `not` operator applied to `in`.

```elixir
# Python: x not in items
# AST: Compare(left=Name("x"), ops=[NotIn], comparators=[Name("items")])
# Elixir: !py_in(x, items)
```

### 9.10 The `len()` Function

Python's `len()` works on lists, tuples, dicts, sets, and strings. Since the transpiler does not perform type inference, it uses a runtime-dispatching helper:

```elixir
defp py_len(x) when is_list(x), do: length(x)
defp py_len(x) when is_binary(x), do: String.length(x)
defp py_len(x) when is_map(x), do: map_size(x)
defp py_len(x) when is_tuple(x), do: tuple_size(x)
```

When the argument is a literal list or a variable assigned from a list literal in the same scope, the converter may emit `length(x)` directly as an optimization. Otherwise, emit `py_len(x)`.

**Note on MapSet:** `MapSet` is a struct (map), so `map_size/1` returns the struct's internal map size, not the set element count. For `MapSet`, use `MapSet.size/1`. The `py_len` helper can be extended with a clause `defp py_len(%MapSet{} = x), do: MapSet.size(x)` placed before the `is_map` clause.

### 9.11 `not` Operator

Python's `not` produces a boolean (`True`/`False`). Elixir's `!` also produces a boolean. However, their truthiness models differ: `not 0` → `True` in Python, `!0` → `false` in Elixir (because `0` is truthy in Elixir). The transpiler always uses `!Pylixir.Helpers.truthy?(x)` instead of `!x` to match Python's truthiness model. See §11.3.

```python
not x    →    !Pylixir.Helpers.truthy?(x)
```

---

## §10. Context Struct Detailed

### 10.1 Context Struct Design

The `Context` struct tracks state needed during conversion. It is threaded through every `convert/2` call via the accumulator pattern.

```elixir
defmodule Pylixir.Context do
  @enforce_keys [:scopes]
  defstruct scopes: [],
            while_counter: 0,
            loop_nesting: 0,
            function_names: MapSet.new(),
            pending_helpers: []

  @type t :: %__MODULE__{
    scopes: [MapSet.t(String.t())],
    while_counter: non_neg_integer(),
    loop_nesting: non_neg_integer(),
    function_names: MapSet.t(String.t()),
    pending_helpers: [Macro.t()]
  }
end
```

### 10.2 Field Details

#### `scopes` — Scope Stack for Variable Tracking

A stack of `MapSet`s, where each `MapSet` contains the variable names bound in that scope. The top of the stack is the current scope.

**Purpose:** Track which variables are bound at each scope level to:
1. Avoid generating conflicting variable names (e.g., when a comprehension uses `x` that shadows an outer `x`)
2. Know which variables need to be threaded through loop accumulators (see §13.4)
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

#### `function_names` — Collected Function Names for Forward References

A `MapSet` of all function names defined at the top level. This is populated during a **pre-pass** over the `Module.body` before the main conversion begins. It allows the converter to recognize calls to functions defined later in the file without raising errors. See §13.20.

#### `pending_helpers` — Deferred Helper Emission

When a `While` loop is encountered, its helper function AST is appended to `pending_helpers`. At the `Module` level, these helpers are prepended to the module body.
