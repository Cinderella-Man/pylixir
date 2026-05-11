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

**This is the single largest semantic gap between Python and Elixir.** The transpiler must handle this with `&&`/`||`/`!` operators (which use Elixir's truthiness — only `nil` and `false` are falsy) and a `truthy?/1` helper function where exact Python truthiness is required. See §11.3.

### 2.7 Python's `and`/`or`/`not` vs Elixir's `and`/`or`/`not`

Python's boolean operators accept any value and return one of the operands (not necessarily a boolean):
- `0 and 5` → `0` (returns the first falsy value)
- `"" or "default"` → `"default"` (returns the first truthy value)
- `not 0` → `True` (always returns a boolean)

Elixir's `and`/`or`/`not` **require boolean operands** and raise `BadBooleanError` on non-booleans:
- `0 and 5` → **raises BadBooleanError**
- `"" or "default"` → **raises BadBooleanError**

**Solution:** The transpiler uses `&&`/`||`/`!` which accept any value in Elixir, matching Python's flexibility (though with Elixir's truthiness model, not Python's).

**`not`/`!` truthiness gap:** Python's `not` uses Python's truthiness: `not 0` → `True`, `not []` → `True`, `not ""` → `True`. Elixir's `!` uses Elixir's truthiness: `!0` → `false`, `![]` → `false`, `!""` → `false`. These disagree on `0`, `[]`, `""`, and `%{}`. The transpiler uses `!truthy?(x)` instead of `!x` to ensure Python truthiness semantics. See §11.3.

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

**Solution:** Use `Integer.floor_div/2`, which floors toward negative infinity.

Similarly, Python's `%` uses floored modulo:
- `-7 % 2` → `1` (Python)
- `rem(-7, 2)` → `-1` (Elixir `rem/2` — different!)

**Solution:** Use `Integer.mod/2`.

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

**Critical: evaluation order.** Python evaluates the entire right-hand side before any assignment. `a, b = b, a` works as a swap because the tuple `(b, a)` is fully constructed first, then destructured. In Elixir, `{a, b} = {b, a}` works the same way — the right side is evaluated before pattern matching. The transpiler must emit a tuple on the right side, not sequential assignments.

### 2.12 The `enumerate` Function

Python's `enumerate` yields `(index, element)` tuples:

```python
for i, x in enumerate(["a", "b"]):
    print(i, x)  # 0 "a", then 1 "b"
```

Elixir's `Enum.with_index/1` yields `{element, index}` tuples — **the order is swapped**. The transpiler must account for this by destructuring with the swapped order: `fn {x, i} -> ... end`.

Python's `enumerate` also accepts a `start` argument: `enumerate(items, 1)` starts indexing at 1. Elixir's `Enum.with_index/2` also accepts an offset: `Enum.with_index(items, 1)`.

### 2.13 The `range` Function

Python's `range` generates integer sequences:
- `range(5)` → `[0, 1, 2, 3, 4]` (stop is exclusive)
- `range(2, 5)` → `[2, 3, 4]` (start inclusive, stop exclusive)
- `range(0, 10, 2)` → `[0, 2, 4, 6, 8]` (with step)
- `range(10, 0, -1)` → `[10, 9, 8, 7, 6, 5, 4, 3, 2, 1]` (negative step, stop exclusive)

Elixir ranges: `0..4//1`, `2..4//1`, `0..8//2` — stop is **inclusive**. The transpiler must adjust the stop boundary based on the step direction:
- Positive step: `range(a, b)` → `a..(b-1)//1`
- Negative step: `range(a, b, -s)` → `a..(b+1)//-s`

See §11.21 for the full conversion rules.

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

### 2.22 Slicing

Python supports extracting sub-sequences with slice notation:

```python
items[1:3]     # elements at index 1, 2 (stop is exclusive)
items[:3]      # first 3 elements
items[2:]      # from index 2 to end
items[::2]     # every other element
items[::-1]    # reversed copy
items[1:5:2]   # elements at index 1, 3
```

Elixir has no built-in slice syntax. The transpiler maps these to `Enum.slice/2`, `Enum.slice/3`, `Enum.take_every/2`, `Enum.reverse/1`, or combinations thereof. See §11.20 for the full translation table.

### 2.23 Dictionary Iteration Methods

Python dicts have methods for iterating over their contents:

```python
for k, v in my_dict.items():    # iterate key-value pairs
for k in my_dict.keys():        # iterate keys (same as `for k in my_dict`)
for v in my_dict.values():      # iterate values
```

These are common in algorithmic code (graph traversals, frequency counting, etc.) and map to Elixir's `Map.to_list/1`, `Map.keys/1`, and `Map.values/1`.

### 2.24 String Concatenation with `+`

Python uses `+` to concatenate strings:

```python
greeting = "hello" + " " + "world"
```

Elixir uses `<>` for string concatenation. The `+` operator on strings raises `ArithmeticError` in Elixir. The transpiler must detect when `+` is used on string operands and emit `<>` instead. See §11.19.

### 2.25 String and List Repetition with `*`

Python uses `*` to repeat strings and lists:

```python
"abc" * 3       # "abcabcabc"
[1, 2] * 3      # [1, 2, 1, 2, 1, 2]
[0] * 10        # [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] — common pattern for initializing arrays
```

This is a `BinOp` with `Mult` operator, where one operand is a string/list and the other is an integer. This pattern is **very common** in competitive programming for initializing arrays (e.g., `dp = [0] * n`, `visited = [False] * n`).

Elixir equivalents:
- `String.duplicate("abc", 3)` for strings
- `List.duplicate(0, 10)` for single-element list repetition like `[0] * 10`
- `List.duplicate([1, 2], 3) |> Enum.concat()` for multi-element list repetition

See §11.23 and §11.24 for the full translation rules.

### 2.26 Boolean Arithmetic

In Python, `bool` is a subclass of `int`. `True` is `1` and `False` is `0` in arithmetic contexts:

```python
True + True     # 2
False + 1       # 1
count += (x > 0)  # increment count if x > 0
sum(x > 0 for x in items)  # count positive items
```

This is **common** in competitive programming for counting conditions. Elixir's `true + true` raises `ArithmeticError`.

See §11.25 for the translation strategy.
