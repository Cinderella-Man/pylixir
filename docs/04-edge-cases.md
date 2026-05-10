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

**The `not`/`!` gap:** This same truthiness mismatch affects the `not` operator. Python's `not 0` → `True`, but Elixir's `!0` → `false`. Python's `not []` → `True`, but Elixir's `![]` → `false`. When the transpiler encounters `not x` and knows `x` could be `0`, `""`, `[]`, or `%{}`, it should generate `!Pylixir.Helpers.truthy?(x)` instead of `!x`. The `truthy?/1` helper implements Python's truthiness model:

```elixir
def truthy?(nil), do: false
def truthy?(false), do: false
def truthy?(0), do: false
def truthy?(0.0), do: false
def truthy?(""), do: false
def truthy?([]), do: false
def truthy?(map) when map == %{}, do: false
def truthy?(_), do: true
```

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

**Performance note:** `Enum.at/2` is O(n) for linked lists, so `arr[mid]` in a binary search becomes an O(n) operation. This is an accepted trade-off — the goal is behavioral correctness, not algorithmic complexity preservation (see §1.2).

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

**Solution:** For `strip(chars)` with a character set, generate a regex-based helper or use `String.replace/3`:

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
| `math.pow(x, n)` | `:math.pow(x, n)` |
| `math.pi` | `:math.pi()` |
| `math.e` | `:math.exp(1)` |
| `math.inf` | `:infinity` |

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

### 11.19 String Concatenation with `+` (Critical)

**Problem:** Python uses `+` for both arithmetic addition and string concatenation. In Elixir, `+` is arithmetic only — string concatenation uses `<>`. Using `+` on strings in Elixir raises `ArithmeticError`.

```python
greeting = "hello" + " " + "world"     # "hello world"
result = str(count) + " items found"   # "5 items found"
```

```elixir
# WRONG: "hello" + " " + "world"  → ArithmeticError
# CORRECT: "hello" <> " " <> "world"
```

**Solution:** The `BinOp` handler for `Add` must determine whether the operands are strings. Detection strategies:

1. **Literal detection:** If both operands are `Constant` nodes with string values, emit `<>`.
2. **Call detection:** If either operand is a call to `str()` (mapped to `to_string/1`), emit `<>`.
3. **Context tracking:** If either operand is a variable known to be a string (from the context struct's type tracking), emit `<>`.
4. **Fallback:** When the type is unknown at transpile time, generate a runtime helper that dispatches based on type:

```elixir
defp py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
defp py_add(a, b), do: a + b
```

**Recommendation:** For the MVP, implement strategies 1–3. When type is unknown and either operand could be a string, emit `py_add(a, b)` and include the helper in the generated module.

### 11.20 Slicing

**Problem:** Python's slice syntax is pervasive in algorithmic code (merge sort, string manipulation, array partitioning). Elixir has no built-in slice syntax.

```python
items[1:3]      # elements at index 1, 2
items[:3]       # first 3 elements
items[2:]       # from index 2 to end
items[::2]      # every other element
items[::-1]     # reversed copy
items[1:5:2]    # elements at index 1, 3
```

**Translation table:**

| Python Slice | Elixir Translation |
|---|---|
| `x[a:b]` (no step) | `Enum.slice(x, a..(b-1))` |
| `x[:b]` (from start) | `Enum.take(x, b)` |
| `x[a:]` (to end) | `Enum.drop(x, a)` |
| `x[:]` (full copy) | `x` (Elixir data is immutable, no copy needed) |
| `x[::n]` (every n-th, positive) | `Enum.take_every(x, n)` |
| `x[::-1]` (reverse) | `Enum.reverse(x)` |
| `x[a:b:n]` (general step) | `Enum.slice(x, a..(b-1)) \|> Enum.take_every(n)` |

**Negative indices in slices:** Python slices support negative indices. `x[-3:]` means "last 3 elements." Elixir's `Enum.slice/2` supports negative indices in ranges, so `Enum.slice(x, -3..-1)` works.

**String slicing:** Python strings support the same slice syntax. For string operands, use `String.slice/2` and `String.slice/3` instead of `Enum.slice`. `s[::-1]` → `String.reverse(s)`.

**The `Slice` AST node:** When `Subscript.slice` is a `Slice` node (rather than a `Constant` or expression), the converter must inspect `Slice.lower`, `Slice.upper`, and `Slice.step` (all optional) and emit the appropriate Elixir translation from the table above.

### 11.21 `range()` with Negative Step

**Problem:** The stop-boundary adjustment for `range()` depends on the step direction. Python's `range` always excludes the stop value.

```python
range(5)           # [0, 1, 2, 3, 4]
range(2, 5)        # [2, 3, 4]
range(0, 10, 2)    # [0, 2, 4, 6, 8]
range(10, 0, -1)   # [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
range(10, 0, -2)   # [10, 8, 6, 4, 2]
```

Elixir ranges are **stop-inclusive**: `0..4` includes `4`. The conversion must adjust the stop boundary:

| Python | Elixir |
|---|---|
| `range(n)` | `0..(n - 1)//1` |
| `range(a, b)` | `a..(b - 1)//1` |
| `range(a, b, s)` where `s > 0` | `a..(b - 1)//s` |
| `range(a, b, s)` where `s < 0` | `a..(b + 1)//s` |

**WRONG:** Using `a..(b-1)//s` for negative steps. `range(10, 0, -1)` would become `10..-1//-1` which includes `-1` and `0` — Python's `range(10, 0, -1)` stops at `1`.

**CORRECT:** For negative steps, add 1 to stop instead of subtracting 1: `range(10, 0, -1)` → `10..1//-1`.

**When step is a runtime variable:** If the step is not a literal (e.g., `range(a, b, step)` where `step` is a variable), the converter cannot determine direction at transpile time. Generate a conditional:

```elixir
if step > 0, do: a..(b - 1)//step, else: a..(b + 1)//step
```

### 11.22 Power Operator (`**`) with Float Exponents

**Problem:** Python's `**` operator works with both integer and float exponents. `2 ** 0.5` computes a square root. Elixir's `Integer.pow/2` only accepts non-negative integer exponents and raises `ArithmeticError` on floats or negative exponents.

```python
2 ** 3      # 8 (integer)
2 ** 0.5    # 1.4142... (float — square root)
2 ** -1     # 0.5 (float — reciprocal)
```

**Solution:** Use `:math.pow/2` as the default translation for `Pow`. It handles all cases (integer and float exponents) and always returns a float.

```elixir
# Python: a ** b
# Elixir: :math.pow(a, b)
```

| Python | Elixir |
|---|---|
| `2 ** 3` | `:math.pow(2, 3)` → `8.0` (float, not integer) |
| `2 ** 0.5` | `:math.pow(2, 0.5)` → `1.4142...` |
| `2 ** -1` | `:math.pow(2, -1)` → `0.5` |

**Trade-off:** `:math.pow/2` always returns a float, so `2 ** 3` returns `8.0` instead of `8`. This can cause type mismatches downstream (e.g., using the result as a list index). When the exponent is a known positive integer literal, the converter may use `Integer.pow/2` instead to preserve the integer type. Otherwise, default to `:math.pow/2`.
