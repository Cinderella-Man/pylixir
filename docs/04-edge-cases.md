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

**Limitation — float operands:** Python's `//` and `%` also work on floats: `7.5 // 2.0` → `3.0`, `-7.5 % 2.0` → `0.5`. `Integer.floor_div/2` and `Integer.mod/2` only accept integers and will raise `ArithmeticError` on floats. For the MVP, document this as a known limitation. A future version could use runtime dispatch: `if is_float(a) or is_float(b), do: :math.floor(a / b)` for float floor division.

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

**Implication:** Code like `if my_list:` (meaning "if not empty") or `not 0` will produce wrong results if translated naively.

**Solution — runtime `truthy?/1` helper:** Rather than attempting compile-time type inference (which would be complex and fragile), the transpiler always uses a `truthy?/1` helper that implements Python's truthiness model:

```elixir
defp truthy?(nil), do: false
defp truthy?(false), do: false
defp truthy?(0), do: false
defp truthy?(0.0), do: false
defp truthy?(""), do: false
defp truthy?([]), do: false
defp truthy?(%MapSet{} = s), do: MapSet.size(s) > 0
defp truthy?(map) when is_map(map) and map_size(map) == 0, do: false
defp truthy?(_), do: true
```

**Note on `MapSet` ordering:** The `%MapSet{}` clause MUST appear before the `is_map` clause. `MapSet` is a struct (backed by a map), so `is_map(MapSet.new())` returns `true`. Without the explicit `%MapSet{}` clause, `map_size(MapSet.new())` would return `2` (for `__struct__` and `map` internal keys), incorrectly making `truthy?(MapSet.new())` return `true`. Python's `set()` is falsy, so the explicit `MapSet.size/1` check is required.

**Translation rules:**

- `if x:` → `if truthy?(x) do ... end`
- `not x` → `!truthy?(x)`
- `x and y` → uses `&&` (Elixir's `&&` short-circuits on `nil`/`false`, which doesn't match Python when `x` is `0` or `""` — but for the MVP, this is an accepted limitation; wrap in `truthy?` if exact Python semantics are needed)
- `while x:` → `if truthy?(x) do ... end` in the recursive helper

**The `not`/`!` gap:** This truthiness mismatch is most dangerous with the `not` operator. Python's `not 0` → `True`, but Elixir's `!0` → `false`. The transpiler always generates `!truthy?(x)` for `not x`.

**Known limitation for `and`/`or`:** Python's `and`/`or` return operand values (not booleans) and use Python truthiness for short-circuiting: `0 and 5` → `0`, `"" or "default"` → `"default"`. Elixir's `&&`/`||` also return operand values but use Elixir truthiness. This means `0 && 5` → `5` in Elixir (because `0` is truthy) but `0 and 5` → `0` in Python (because `0` is falsy). For code where `and`/`or` is used purely for boolean logic (the common case in algorithmic code), `&&`/`||` works correctly. For code that exploits Python's short-circuit value semantics with non-boolean operands, the translation will be wrong. Document as a known limitation.

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

**Problem:** Python's `enumerate` yields `(index, element)` tuples. Elixir's `Enum.with_index` yields `{element, index}` tuples — the order is swapped.

```python
for i, x in enumerate(["a", "b", "c"]):
    print(i, x)  # 0 "a", 1 "b", 2 "c"
```

**Solution:** When `enumerate` appears as the iterator of a `for` loop with tuple unpacking, destructure the swapped order in the `fn` parameter. Do NOT add a separate `Enum.map` to swap — just bind correctly:

```elixir
# Python: for i, x in enumerate(items): body
# Elixir:
Enum.reduce(Enum.with_index(items), acc, fn {x, i}, acc ->
  # body uses i and x correctly — they're just bound in the right order
  ...
end)
```

The key insight is that `Enum.with_index` returns `{element, index}`, so the `fn` parameter destructures as `{x, i}` even though the Python code writes `i, x`. No tuple-swapping step is needed.

For `enumerate` with a start offset: `enumerate(items, 1)` → `Enum.with_index(items, 1)`.

### 11.8 Negative Indexing

**Problem:** Python supports negative indexing (`my_list[-1]` = last element). Elixir's `Enum.at/2` also supports negative indices, so this maps directly.

```elixir
Enum.at(my_list, -1)  # last element — works!
```

**No special handling needed** — `Enum.at/2` handles negative indices correctly.

**Performance note:** `Enum.at/2` is O(n) for linked lists, so `arr[mid]` in a binary search becomes an O(n) operation. This is an accepted trade-off — the goal is behavioral correctness, not algorithmic complexity preservation (see §1.3).

### 11.9 `sorted()` with `key` Function

**Problem:** Python's `sorted(items, key=lambda x: x[1])` sorts by a key function. Elixir's `Enum.sort_by/3` does the same.

```elixir
Enum.sort_by(items, fn x -> Enum.at(x, 1) end)
```

**No special handling needed** — `Enum.sort_by/3` is a direct mapping.

### 11.10 `zip` with Unequal Lengths

**Problem:** Python's `zip` stops at the shortest iterable. Elixir's `Enum.zip` also stops at the shortest. No semantic gap.

### 11.11 Dictionary Key Access

**Problem:** Python's `d[key]` raises `KeyError` if key is missing. The converter must use `Map.fetch!/2` (not `Map.get/2`) to match this behavior.

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

**Important:** Do NOT use `Map.get/2` or `d[key]` (Elixir's Access syntax) for Python's `d[key]` — Elixir's `d[key]` returns `nil` for missing keys instead of raising, which would silently produce wrong results.

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
hex(255)   # "0xff"   (lowercase!)
oct(255)   # "0o377"
bin(255)   # "0b11111111"
```

```elixir
Integer.to_string(255, 16)  # "FF" — WRONG CASE, missing "0x" prefix
Integer.to_string(255, 8)   # "377" — missing "0o" prefix
Integer.to_string(255, 2)   # "11111111" — missing "0b" prefix
```

**Solution:** Generate helpers that add the prefix and fix casing:
```elixir
"0x" <> String.downcase(Integer.to_string(n, 16))   # hex — Python uses lowercase
"0o" <> Integer.to_string(n, 8)                       # oct
"0b" <> Integer.to_string(n, 2)                       # bin
```

**Important:** Python's `hex()` returns lowercase hex digits (`0xff`, not `0xFF`). Elixir's `Integer.to_string(n, 16)` returns uppercase (`FF`). The `String.downcase/1` call is required.

### 11.16 `input()` Function

**Problem:** Python's `input()` reads a line from stdin. Elixir's equivalent is `IO.gets/1`.

```elixir
IO.gets("") |> String.trim_trailing("\n")
```

**Solution:** Map `input()` to `IO.gets("") |> String.trim_trailing("\n")`. Map `input(prompt)` to `IO.gets(prompt) |> String.trim_trailing("\n")`. Note: `String.trim_trailing("\n")` specifically strips only the trailing newline, matching Python's `input()` behavior (which does not strip other whitespace).

**Gotcha — EOF handling:** `IO.gets/1` returns the atom `:eof` when stdin is closed or exhausted. `String.trim_trailing(:eof, "\n")` raises `FunctionClauseError`. Python's `input()` raises `EOFError` in this case. For the MVP, the crash is an acceptable analog (both are runtime errors). A more robust version could use a helper:

```elixir
defp py_input(prompt) do
  case IO.gets(prompt) do
    :eof -> raise RuntimeError, "EOFError"
    line -> String.trim_trailing(line, "\n")
  end
end
```

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
| `math.gcd(a, b, c, ...)` | Reduce: `Enum.reduce([a, b, c, ...], &Integer.gcd/2)` (Python 3.9+) |
| `math.pow(x, n)` | `:math.pow(x, n)` |
| `math.pi` | `:math.pi()` |
| `math.e` | `:math.exp(1)` |
| `math.inf` | See note below |

**`math.inf` has no safe Elixir equivalent.** Python's `math.inf` is an IEEE 754 positive infinity float. It participates in arithmetic (`1 + math.inf` → `inf`) and comparisons (`x < math.inf` → `True` for any finite `x`). Elixir's `:infinity` atom has no numeric semantics — `1 + :infinity` raises `ArithmeticError`, and `x < :infinity` uses atom comparison (different from numeric comparison). **Solution:** Raise `UnsupportedNodeError` when `math.inf` is encountered. If a future version needs to support it, use a large float sentinel (e.g., `1.0e308`) with a comment documenting the limitation, or define a helper module with custom comparison functions.

### 11.18 `print()` with Multiple Arguments

**Problem:** Python's `print(a, b, c)` prints values separated by spaces. Elixir's `IO.puts/1` only takes one argument.

```python
print(a, b, c)     # "1 2 3"
print(a, sep=",")  # "1,2,3"
print()             # "" (prints empty line)
```

```elixir
# Single argument:
IO.puts(to_string(a))

# Multiple arguments:
IO.puts(Enum.join([to_string(a), to_string(b), to_string(c)], " "))

# No arguments:
IO.puts("")
```

**Solution:** For `print()` (no arguments), map to `IO.puts("")`. For `print(arg)` (single argument), map to `IO.puts(py_str(arg))`. For `print(arg1, arg2, ...)`, map to `IO.puts(Enum.join([py_str(arg1), py_str(arg2), ...], " "))`. For `print(..., sep=..., end=...)`, generate the appropriate `Enum.join` with custom separator and `IO.write` instead of `IO.puts` for custom end.

**Critical: `to_string/1` does NOT match Python's `str()` for booleans and `None`.** Python's `print(True)` outputs `True` (capital T), `print(False)` outputs `False` (capital F), and `print(None)` outputs `None`. Elixir's `to_string(true)` returns `"true"` (lowercase), `to_string(false)` returns `"false"` (lowercase), and `to_string(nil)` returns `""` (empty string). Use a `py_str/1` helper instead of `to_string/1`:

```elixir
defp py_str(true), do: "True"
defp py_str(false), do: "False"
defp py_str(nil), do: "None"
defp py_str(x) when is_atom(x), do: Atom.to_string(x)
defp py_str(x) when is_list(x), do: py_repr_list(x)
defp py_str(x) when is_tuple(x), do: py_repr_tuple(x)
defp py_str(x) when is_map(x), do: py_repr_map(x)
defp py_str(x), do: to_string(x)

defp py_repr_list(items) do
  inner = Enum.map_join(items, ", ", &py_repr/1)
  "[" <> inner <> "]"
end

defp py_repr_tuple(t) do
  items = Tuple.to_list(t)
  case items do
    [single] -> "(" <> py_repr(single) <> ",)"
    _ -> "(" <> Enum.map_join(items, ", ", &py_repr/1) <> ")"
  end
end

defp py_repr_map(m) do
  inner = Enum.map_join(m, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end)
  "{" <> inner <> "}"
end

defp py_repr(x) when is_binary(x), do: "'" <> x <> "'"
defp py_repr(x), do: py_str(x)
```

**Why `to_string/1` is wrong for compound types:**
- `to_string([65, 66])` returns `"AB"` (treats list as charlist), not `"[65, 66]"`.
- `to_string({1, 2})` raises `Protocol.UndefinedError` (tuples don't implement `String.Chars`).
- `to_string(%{a: 1})` raises `Protocol.UndefinedError` (maps don't implement `String.Chars`).

The `py_repr/1` helper wraps strings in quotes (Python's `repr()` behavior for strings inside collections) to match Python's `str([1, "a"])` → `"[1, 'a']"`.

**Known limitation:** This does not handle all Python repr edge cases (e.g., escaping quotes inside strings, nested quote style alternation). For the MVP, single-quote wrapping is sufficient.

**Failure mode:** Silent wrong output. Any test that captures IO and compares against Python's output will fail on `True`/`False`/`None` values.

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

**Solution — runtime `py_add/2` helper:** Rather than attempting compile-time type inference, the transpiler uses a runtime-dispatching helper for all `Add` operations:

```elixir
defp py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
defp py_add(a, b) when is_list(a) and is_list(b), do: a ++ b
defp py_add(a, b), do: a + b
```

This handles both string concatenation (`"hello" + " world"`) and list concatenation (`[1, 2] + [3, 4]` → `[1, 2, 3, 4]`), which are both valid uses of `+` in Python. All `BinOp` `Add` nodes emit `py_add(a, b)`. This is simple, correct, and avoids the complexity of tracking string types through the context struct. The `py_add` helper is unconditionally included in the generated module (it's a no-op if never called).

See §11.24 for the extended version of `py_add` that also handles boolean operands.

### 11.20 String and List Repetition with `*` (Critical)

**Problem:** Python uses `*` for both arithmetic multiplication, string repetition, and list repetition. In Elixir, `*` is arithmetic only.

```python
"abc" * 3           # "abcabcabc"
[1, 2] * 3          # [1, 2, 1, 2, 1, 2]
```

```elixir
# WRONG: "abc" * 3  → ArithmeticError
# CORRECT:
String.duplicate("abc", 3)             # "abcabcabc"
List.duplicate([1, 2], 3) |> Enum.concat()  # [1, 2, 1, 2, 1, 2]
```

**Solution — runtime `py_mult/2` helper:**

```elixir
defp py_mult(a, b) when is_binary(a) and is_integer(b), do: String.duplicate(a, b)
defp py_mult(a, b) when is_integer(a) and is_binary(b), do: String.duplicate(b, a)
defp py_mult(a, b) when is_list(a) and is_integer(b), do: List.duplicate(a, b) |> Enum.concat()
defp py_mult(a, b) when is_integer(a) and is_list(b), do: py_mult(b, a)
defp py_mult(a, b) when is_boolean(a), do: py_mult(py_bool_to_int(a), b)
defp py_mult(a, b) when is_boolean(b), do: py_mult(a, py_bool_to_int(b))
defp py_mult(a, b), do: a * b
```

**Note on boolean handling in `py_mult`:** Python's `True * 3` returns `3` and `False * 5` returns `0` because `bool` is a subclass of `int`. In Elixir, `true * 3` raises `ArithmeticError`. The `is_boolean` clauses convert booleans to integers before dispatching. These clauses must appear before the catch-all `a * b` clause but after the `is_binary`/`is_list` clauses (a boolean operand with a string or list would be a `TypeError` in Python too, so the ordering doesn't matter for those cases).

**CRITICAL: Use `Enum.concat/1`, NOT `List.flatten/1`.** `Enum.concat/1` flattens exactly one level of nesting, which is correct. `List.flatten/1` recursively flattens ALL levels, which would corrupt nested list repetition:

```elixir
# Python: [[1, 2]] * 3  →  [[1, 2], [1, 2], [1, 2]]
List.duplicate([[1, 2]], 3) |> Enum.concat()     # [[1, 2], [1, 2], [1, 2]] ✓
List.duplicate([[1, 2]], 3) |> List.flatten()     # [1, 2, 1, 2, 1, 2] ✗ WRONG
```

**Static optimization (optional):** When the AST shows a single-element list literal like `[0] * n`, the converter can emit `List.duplicate(0, n)` directly (unwrapping the element), which is cleaner and avoids the `Enum.concat` step. This is common in competitive programming for initializing arrays (`dp = [0] * n`, `visited = [False] * n`).

### 11.21 Slicing

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
| `x[a::n]` (from offset, every n-th) | `Enum.drop(x, a) \|> Enum.take_every(n)` |
| `x[::-1]` (reverse) | `Enum.reverse(x)` |
| `x[a:b:n]` (general step) | `Enum.slice(x, a..(b-1)) \|> Enum.take_every(n)` |

**Negative indices in slices:** Python slices support negative indices. `x[-3:]` means "last 3 elements." Elixir's `Enum.slice/2` supports negative indices in ranges, so `Enum.slice(x, -3..-1)` works.

**String slicing:** Python strings support the same slice syntax. For string operands, use `String.slice/2` and `String.slice/3` instead of `Enum.slice`. `s[::-1]` → `String.reverse(s)`.

**String character access:** Python's `s[i]` on a string returns a single-character string. This must use `String.at(s, i)` in Elixir, NOT `Enum.at/2` (which would iterate over bytes/graphemes incorrectly). Since the transpiler does not track types, the `py_getitem` runtime helper must include a `is_binary` clause. See §12.5.

**The `Slice` AST node:** When `Subscript.slice` is a `Slice` node (rather than a `Constant` or expression), the converter must inspect `Slice.lower`, `Slice.upper`, and `Slice.step` (all optional) and emit the appropriate Elixir translation from the table above.

### 11.22 `range()` with Negative Step

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

### 11.23 Power Operator (`**`) with Float Exponents

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

**Known limitation — large integer exponents:** Python supports arbitrary-precision integer exponents: `2 ** 1000` returns a huge exact integer. `:math.pow(2, 1000)` returns approximately `1.07e301` (IEEE 754 float), and `:math.pow(2, 1024)` returns `:infinity` (float overflow). This is a significant difference for competitive programming where large exponents on integers are common (e.g., modular exponentiation). **Mitigation:** When both operands are known to be integers at transpile time (both are `Constant` nodes with integer values, or variables in an integer-only context), prefer `Integer.pow/2`. For runtime-determined exponents, a helper can dispatch:

```elixir
defp py_pow(base, exp) when is_integer(base) and is_integer(exp) and exp >= 0, do: Integer.pow(base, exp)
defp py_pow(base, exp), do: :math.pow(base, exp)
```

This preserves exact integer arithmetic when possible and falls back to float for fractional/negative exponents.

### 11.24 Boolean Values in Arithmetic (Critical)

**Problem:** In Python, `bool` is a subclass of `int` — `True` is `1` and `False` is `0` in arithmetic contexts. Elixir's `true` and `false` are atoms with no numeric value.

```python
True + True       # 2
False + 1         # 1
sum([True, True, False])  # 2
count = count + (x > 0)   # common idiom: adds 1 if x > 0, else 0
```

```elixir
# WRONG: true + true  → ArithmeticError
# WRONG: false + 1    → ArithmeticError
```

**Solution — runtime `py_add/2` already handles this partially**, but the `count + (x > 0)` idiom is especially common in competitive programming. The `py_add` helper should be extended:

```elixir
defp py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
defp py_add(a, b) when is_boolean(a), do: py_add(bool_to_int(a), b)
defp py_add(a, b) when is_boolean(b), do: py_add(a, bool_to_int(b))
defp py_add(a, b), do: a + b

defp bool_to_int(true), do: 1
defp bool_to_int(false), do: 0
```

**Note:** The `is_boolean` clauses must come before the catch-all `py_add(a, b), do: a + b` clause, since `a + b` would crash on boolean operands. (In Elixir, `is_integer(true)` returns `false`, so there is no guard-ordering conflict between `is_boolean` and `is_number`/`is_integer` — they don't overlap.) The `py_mult` helper should handle booleans similarly.

**Failure mode:** Silent crash (`ArithmeticError`) in code that uses boolean-integer arithmetic. This pattern is common in competitive programming where `count += (condition)` is idiomatic Python.
