## §13. Implementation Notes

### 13.1 Output Module

- Generated Elixir code wraps everything in a `defmodule TranslatedCode do ... end` block.
- Python function definitions become `defp` (private functions).
- The module has a single `def run do ... end` public function that contains all top-level (non-function) statements from the Python source.
- `import Bitwise` is unconditionally included at the top of the module. It is a no-op when no bitwise operators are used, and avoids the need to track bitwise usage through the context struct.
- The generated code ends with `TranslatedCode.run()` to execute the entry point.

### 13.2 The `convert/2` Function Pattern

```elixir
def convert(%{"_type" => "Module", "body" => body}, %Context{} = context) do
  {stmts, context} = convert_many(body, context)
  helpers = context.pending_helpers
  bitwise_import = [quote do: import Bitwise]
  body = bitwise_import ++ helpers ++ stmts
  {:__block__, [], body}
end
```

**Pattern:** Match on the `_type` field. Return `{elixir_ast, updated_context}`.

### 13.3 String-Binary Equivalence

In Elixir, strings ARE binaries. `"hello" == <<104, 101, 108, 108, 111>>`. This means Python code that treats strings as byte arrays (indexing, slicing) does NOT translate directly. Elixir strings are UTF-8 encoded, so `String.at("hello", 0)` returns `"h"`, but `"hello"[0]` in Python returns `"h"` as well (Python 3 strings are also Unicode). The key difference is that Elixir's `String.length/1` counts grapheme clusters while Python's `len()` counts code points — these differ for some Unicode characters.

**Recommendation:** Use `String.at/2` for character access and `String.length/1` for length. Document that multi-codepoint grapheme clusters may behave differently.

### 13.4 For-Loop State Threading with `Enum.reduce`

Python `for` loops frequently mutate variables from the enclosing scope. In Elixir, closures passed to `Enum.each/2` cannot modify outer-scope bindings — variable rebinding inside `fn` is local to that closure. The solution is `Enum.reduce/3`, which threads state through an accumulator.

**The core pattern:**

```python
# Python:
total = 0
count = 0
for x in items:
    total += x
    count += 1
```

```elixir
# Elixir:
{total, count} = Enum.reduce(items, {0, 0}, fn x, {total, count} ->
  total = total + x
  count = count + 1
  {total, count}
end)
```

**Detection strategy:** The converter must determine which variables inside the loop body are "external" (defined before the loop and used/modified inside it). The algorithm:

1. **Before converting the loop body**, record the current scope's bound variables.
2. **Walk the loop body** and collect all variables that are assigned to (`Assign`, `AugAssign` targets).
3. **Intersect** the assigned variables with the pre-loop scope. Variables in the intersection are "mutated externals" — they must be threaded through the accumulator.
4. **Also include** variables assigned inside the loop that are used after the loop (these need to be returned from the reduce).

**Translation rules:**

- **No mutated externals:** Use `Enum.each/2` (pure side effects like `print`).
- **One mutated external:** Use `Enum.reduce/3` with a simple accumulator: `Enum.reduce(items, initial, fn x, acc -> ... end)`.
- **Multiple mutated externals:** Use `Enum.reduce/3` with a tuple accumulator: `Enum.reduce(items, {a, b, c}, fn x, {a, b, c} -> ... {a, b, c} end)`. Destructure the result after the reduce.

**Example with break:**

```python
result = -1
for i, x in enumerate(items):
    if x == target:
        result = i
        break
```

```elixir
result = try do
  Enum.reduce(Enum.with_index(items), -1, fn {x, i}, result ->
    if x == target, do: throw({:break, i})
    result
  end)
catch
  {:break, val} -> val
end
```

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
defmodule Pylixir.Errors.UnsupportedNodeError do
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

defmodule Pylixir.Errors.UndefinedNameError do
  defexception [:message, :name]

  @impl true
  def exception(opts) do
    name = Keyword.fetch!(opts, :name)
    %__MODULE__{message: "Undefined name: #{name}", name: name}
  end
end
```

### 13.7 `while` Loop Implementation Detail

The `while` loop uses recursive helper functions for the loop body, with `try`/`throw`/`catch` for `break`:

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

**Key points:**
- Each `while` loop becomes a private function that threads mutable state via its arguments.
- `continue` is implemented by recursing immediately with the current state, skipping the remaining body.
- `break` throws a `:break` tag caught by the enclosing `try`/`catch`.
- The helper function body must call itself recursively to loop.

### 13.8 Comparison Chain Conversion

For `Compare` nodes with multiple operators, generate a left-associative `&&` chain:

```elixir
def convert(%{"_type" => "Compare", "left" => left, "ops" => ops, "comparators" => comparators}, ctx) do
  {left_ast, ctx} = convert(left, ctx)
  pairs = Enum.zip(ops, comparators)

  {comparisons, _prev, ctx} =
    Enum.reduce(pairs, {[], left_ast, ctx}, fn {op, comp}, {acc, prev_left, ctx} ->
      {op_ast, ctx} = convert_op(op, ctx)
      {comp_ast, ctx} = convert(comp, ctx)
      comparison = {op_ast, [], [prev_left, comp_ast]}
      {acc ++ [comparison], comp_ast, ctx}
    end)

  # Chain with && (left-associative fold)
  result = Enum.reduce(comparisons, fn right, left -> {:&&, [], [left, right]} end)
  {result, ctx}
end
```

> **Key detail:** The accumulator threads `comp_ast` as `prev_left` into the next iteration. For `a < b < c`, this correctly produces `(a < b) && (b < c)`. The comparisons list is built in order via `acc ++ [comparison]`, then the left-associative `Enum.reduce/2` (no initial accumulator) folds them into nested `&&` tuples.

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
  "Is"    => :==,
  "IsNot" => :!=,
  "In"    => :in,
  "NotIn" => :not_in  # special handling: negate the :in result
}
```

**Note on `Is`/`IsNot`:** Python's `is` checks object identity, but in algorithmic code it is almost exclusively used as `x is None` or `x is not None`. Mapping `is` to `==` (value equality) is correct for this use case. The distinction between `==` and `===` in Elixir (`1 == 1.0` is `true`, `1 === 1.0` is `false`) is not relevant here — Python's `is` is never used to compare integers with floats.

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

When a Python function contains a `return` statement inside a `for` or `while` loop, the translation is complex because Elixir's `Enum.reduce` or `for` comprehension cannot "return" from the enclosing function.

**Solution:** Use `try`/`throw`/`catch` at the function level:

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

**Important:** The `return` value is wrapped in `{:return, value}` to distinguish it from other throws (like `:break`). The `catch` clause unwraps it. The `try`/`catch` wraps the entire function body, not just the loop — a single `try`/`catch` at the function level handles returns from any depth.

### 13.14 Slicing Implementation

When `Subscript.slice` is a `Slice` node, the converter inspects `lower`, `upper`, and `step` to determine the translation:

```elixir
def convert_subscript_slice(value_ast, %{"_type" => "Slice"} = slice, ctx) do
  lower = Map.get(slice, "lower")
  upper = Map.get(slice, "upper")
  step  = Map.get(slice, "step")

  case {lower, upper, step} do
    {nil, nil, nil} ->
      # x[:] — full copy (no-op in Elixir, data is immutable)
      {value_ast, ctx}

    {nil, nil, %{"_type" => "UnaryOp", "op" => %{"_type" => "USub"}, "operand" => %{"_type" => "Constant", "value" => 1}}} ->
      # x[::-1] — reverse
      {quote(do: Enum.reverse(unquote(value_ast))), ctx}

    {lower, upper, nil} ->
      # x[a:b] — basic slice
      {lower_ast, ctx} = if lower, do: convert(lower, ctx), else: {0, ctx}
      {upper_ast, ctx} = convert(upper, ctx)
      range_ast = quote do: unquote(lower_ast)..(unquote(upper_ast) - 1)
      {quote(do: Enum.slice(unquote(value_ast), unquote(range_ast))), ctx}

    # ... additional patterns for step, negative indices, etc.
  end
end
```

### 13.15 String Concatenation Detection

When converting `BinOp` with `Add`, the converter must determine whether to emit `+` or `<>`. The detection cascade:

1. **Both operands are string `Constant` nodes** → emit `<>`
2. **Either operand is a `Call` to `str()`** (mapped to `to_string/1`) → emit `<>`
3. **Either operand is a variable known (via context) to be a string** → emit `<>`
4. **Type is unknown** → emit `py_add(a, b)` helper call

The `py_add` helper is included in the generated module when needed:

```elixir
defp py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
defp py_add(a, b), do: a + b
```

### 13.16 Power Operator Dispatch

The `Pow` operator in `BinOp` uses `:math.pow/2` by default, which always returns a float. When the exponent is a known non-negative integer literal, `Integer.pow/2` can be used instead to preserve integer types:

```elixir
def convert_pow(base_ast, %{"_type" => "Constant", "value" => exp}, ctx) when is_integer(exp) and exp >= 0 do
  {quote(do: Integer.pow(unquote(base_ast), unquote(exp))), ctx}
end

def convert_pow(base_ast, exp_ast, ctx) do
  {quote(do: :math.pow(unquote(base_ast), unquote(exp_ast))), ctx}
end
```

### 13.17 Formatter Pipeline

The final output pipeline must handle the `iodata` return type of `Code.format_string!/1`:

```elixir
def to_source(python_ast) do
  context = %Pylixir.Context{scopes: [MapSet.new()]}
  {elixir_ast, _context} = convert(python_ast, context)

  elixir_ast
  |> Macro.to_string()        # returns binary string
  |> Code.format_string!()    # returns iodata (NOT binary!)
  |> IO.iodata_to_binary()    # returns binary string
end
```

Both `Macro.to_string/1` and the final `IO.iodata_to_binary/1` return binary strings. The intermediate `Code.format_string!/1` is the only step that returns iodata.
