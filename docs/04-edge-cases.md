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


