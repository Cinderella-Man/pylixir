## §13. Implementation Notes

### 13.1 Output Module

- Generated Elixir code wraps everything in a `defmodule TranslatedCode do ... end` block.
- Python function definitions become `defp` (private functions).
- The module has a single `def run do ... end` public function that contains all top-level (non-function) statements from the Python source.
- `import Bitwise` is unconditionally included at the top of the module. It is a no-op when no bitwise operators are used, and avoids the need to track bitwise usage through the context struct. **Note:** `use Bitwise` is deprecated; use `import Bitwise` instead. See §7.1 for the `^^^` deprecation note.
- The generated code ends with `TranslatedCode.run()` to execute the entry point.
- The module includes runtime helper functions (`py_add/2`, `py_mult/2`, `py_pow/2`, `py_len/1`, `py_in/2`, `py_getitem/2`, `py_setitem/3`, `py_int/1`, `py_float/1`, `py_str/1`, `py_bool_to_int/1`, `truthy?/1`, `py_str_find/2`, `py_str_count/2`, `py_list_index/2`, `py_repr/1`) as needed. These are emitted unconditionally in the MVP for simplicity; a later optimization can prune unused helpers.

### 13.2 The `convert/2` Function Pattern

```elixir
def convert(%{"_type" => "Module", "body" => body}, %Context{} = context) do
  {stmts, context} = convert_many(body, context)
  bitwise_import = [quote do: import Bitwise]
  body = bitwise_import ++ stmts
  {{:__block__, [], body}, context}
end
```

**Pattern:** Match on the `_type` field. Return `{elixir_ast, updated_context}`.

**Note on while loop helpers:** While-loop helper `defp` functions are emitted inline within the statement list by the `While` handler. Elixir does not require function definitions to appear before their callers within a module, so no special ordering or deferred collection is needed.

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

1. **Before converting the loop body**, snapshot the current scope's bound variables as `pre_loop_vars`.
2. **Walk the loop body AST** (without converting) and collect two sets:
   - `assigned_vars`: all variable names that appear as `Assign.targets` or `AugAssign.target` (recursing into `Tuple.elts` for unpacking targets, and into nested `If`/`While` bodies — a variable assigned in any branch counts).
   - `read_vars`: all variable names that appear as `Name` with `ctx: Load` anywhere in the body.
3. **Compute mutated externals:** `mutated_externals = assigned_vars ∩ pre_loop_vars`. These are pre-existing variables that the loop body reassigns.
4. **Compute new variables used post-loop:** This requires look-ahead. Scan the statements AFTER the `For` node in the parent body for `Name` nodes with `ctx: Load`. Any name in `assigned_vars` (but not in `pre_loop_vars`) that is read post-loop must also be included in the accumulator. **Simplification for MVP:** Conservatively include ALL `assigned_vars` (not just externals) in the accumulator. This over-captures but is always correct.

```elixir
defp collect_assigned_vars(%{"_type" => "Assign", "targets" => targets}, acc) do
  Enum.reduce(targets, acc, &collect_target_names/2)
end
defp collect_assigned_vars(%{"_type" => "AugAssign", "target" => target}, acc) do
  collect_target_names(target, acc)
end
defp collect_assigned_vars(%{"_type" => "If", "body" => body, "orelse" => orelse}, acc) do
  acc = Enum.reduce(body, acc, &collect_assigned_vars/2)
  Enum.reduce(orelse, acc, &collect_assigned_vars/2)
end
defp collect_assigned_vars(_, acc), do: acc

defp collect_target_names(%{"_type" => "Name", "id" => name}, acc), do: MapSet.put(acc, name)
defp collect_target_names(%{"_type" => "Tuple", "elts" => elts}, acc) do
  Enum.reduce(elts, acc, &collect_target_names/2)
end
defp collect_target_names(_, acc), do: acc
```

**Translation rules:**

- **No mutated externals:** Use `Enum.each/2` (pure side effects like `print`).
- **One mutated external:** Use `Enum.reduce/3` with a simple accumulator: `Enum.reduce(items, initial, fn x, acc -> ... end)`.
- **Multiple mutated externals:** Use `Enum.reduce/3` with a tuple accumulator: `Enum.reduce(items, {a, b, c}, fn x, {a, b, c} -> ... {a, b, c} end)`. Destructure the result after the reduce.

**`continue` in for loops:** When `continue` appears inside a `for` loop body translated as `Enum.reduce`, it means "return the accumulator unchanged, skip the rest of the body." The transpiler emits the accumulator tuple as an early return from the anonymous function. See §11.26.

**Nested for loops with shared mutation:** When nested `for` loops modify the same outer variable, the inner loop becomes a nested `Enum.reduce`. The inner reduce receives the outer accumulator as its initial value and returns the updated value. See §11.27.

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

**Generalized break with multiple accumulated variables:** When the loop body modifies multiple variables and also contains `break`, the throw must carry the full accumulator tuple — not just one variable:

```python
total = 0
found_idx = -1
for i, x in enumerate(items):
    total += x
    if x == target:
        found_idx = i
        break
```

```elixir
{total, found_idx} = try do
  Enum.reduce(Enum.with_index(items), {0, -1}, fn {x, i}, {total, found_idx} ->
    total = total + x
    if x == target do
      throw({:break, {total, found_idx = i}})
    end
    {total, found_idx}
  end)
catch
  {:break, state} -> state
end
```

The `throw` carries the full `{total, found_idx}` tuple, and the `catch` returns the tuple for destructuring. The pattern is always: `throw({:break, {all, accumulated, vars}})`, `catch {:break, state} -> state`.

### 13.5 List Comprehension Optimization

For simple list comprehensions, prefer Elixir's `for` comprehension over `Enum.map` + `Enum.filter`:

```elixir
# Preferred: Elixir for comprehension
for x <- items, x > 0, do: x * 2

# Less preferred: Enum chain
items |> Enum.filter(&(&1 > 0)) |> Enum.map(&(&1 * 2))
```

Both produce the same result, but the `for` comprehension is more idiomatic and can be more efficient for multiple generators.

### 13.6 Function Name Collection (Two-Pass)

Before converting the module body, the converter performs a lightweight first pass to collect all function names defined at the module level:

```elixir
def collect_function_names(body) do
  body
  |> Enum.filter(fn node -> node["_type"] == "FunctionDef" end)
  |> Enum.map(fn node -> node["name"] end)
  |> MapSet.new()
end
```

These names are stored in `context.known_functions`. When the converter encounters a `Call` to a `Name` that is not in the builtins table and not in the current scope, it checks `known_functions` before raising an error. If the name is in `known_functions`, the call is emitted as-is — the Elixir compiler will resolve it at compile time.

This avoids false errors when a function is called before its definition in the source file (which is valid in Python, since Python resolves function names at call time, not definition time).

For truly unknown names (not in builtins, not in scope, not in `known_functions`), the converter emits the call as-is and lets the Elixir compiler produce the error. This is simpler and more reliable than trying to reproduce Elixir's name resolution logic.

### 13.7 Error Handling

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
```

### 13.8 `while` Loop Implementation Detail

The `while` loop uses recursive helper functions for the loop body, with `try`/`throw`/`catch` for `break`. **Critically, the helper function must return its state so the caller can use the final values.**

```elixir
# Python:
# x = 1
# while x < 100:
#     x = x * 2
# print(x)

# Elixir:
defp while_0(x) do
  if x < 100 do
    x = x * 2
    while_0(x)
  else
    {x}  # return final state as tuple
  end
end

# No break in this loop, so no try/catch needed:
{x} = while_0(1)
IO.puts(to_string(x))
```

**Key points:**
- Each `while` loop becomes a private function that threads mutable state via its arguments.
- **The helper must return the final state as a tuple** when the loop condition becomes false. The caller destructures this tuple to rebind the variables.
- `continue` is implemented by recursing immediately with the current state, skipping the remaining body.
- **When the loop body contains `break`:** wrap the call in `try`/`catch`. The `break` throw carries state: `throw({:break, {x}})`, caught as `{:break, state} -> state`. See the example below.
- **When the loop body does NOT contain `break`:** no `try`/`catch` is needed — just call the helper directly and destructure the result.
- The helper function body must call itself recursively to loop.

**Read-only variables (critical):** The while helper function needs ALL outer-scope variables referenced in the loop body as arguments — not just the ones it mutates. Variables that the loop reads but doesn't write (e.g., `arr` and `target` in a binary search while loop) must be passed as extra arguments so the recursive helper can access them. The detection algorithm should:

1. Walk the loop body to find **all** `Name` nodes with `ctx: Load` → these are read variables.
2. Walk the loop body to find **all** assignment targets → these are written variables.
3. The helper's parameters are: `written_vars ∪ (read_vars ∩ outer_scope_vars)`. Written vars are the mutable state; read-only vars are passed through unchanged on each recursive call.
4. Only the written vars are returned in the state tuple; read-only vars are not destructured by the caller.

See the binary search example in §19, where `arr` and `target` are read-only parameters of `while_0`.

**While loop with `break` carrying state:**

```elixir
# Python:
# count = 0
# while count < 5:
#     count += 1
#     if count == 3:
#         continue
#     if count == 5:
#         break
#     print(count)

# Elixir:
defp while_0(count) do
  if count < 5 do
    count = count + 1
    if count == 3 do
      while_0(count)  # continue: skip rest, recurse immediately
    else
      if count == 5 do
        throw({:break, {count}})  # break: carry state
      else
        IO.puts(to_string(count))
        while_0(count)
      end
    end
  else
    {count}  # loop ended normally: return state
  end
end

{count} = try do
  while_0(0)
catch
  {:break, state} -> state
end
```

### 13.9 Comparison Chain Conversion

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

### 13.10 The `AugAssign` Subscript Pattern

When `AugAssign.target` is a `Subscript` node (e.g., `d[key] += 1`), the translation uses a runtime-dispatching helper for the collection update. For dicts, the translation preserves Python's `KeyError` on missing keys by using `Map.fetch!/2`:

```elixir
# Python: d[key] += 1
# Elixir: d = py_setitem(d, key, py_getitem(d, key) + 1)
# Which, for dicts, evaluates to: d = Map.put(d, key, Map.fetch!(d, key) + 1)
# For lists: my_list = List.replace_at(my_list, i, Enum.at(my_list, i) + 1)
```

**Important:** Use `Map.fetch!/2` (not `Map.get/3` with a default) — Python's `d[key] += 1` raises `KeyError` if `key` is missing (see §9.3).

The `convert/2` function for `AugAssign` must check if `target["_type"]` is `"Subscript"` and handle it differently from simple variable augmentation. Since the transpiler does not perform type inference, use the `py_getitem`/`py_setitem` runtime helpers (see §9.3 and §13.20).

### 13.11 Comparison Operator AST Mapping

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

### 13.12 If-Elif-Else Chain Conversion

All `if`/`elif`/`else` chains are converted to `cond` blocks. This is simpler to implement (one code path instead of two) and produces cleaner output for multi-branch chains.

**Critical: Condition wrapping with `truthy?/1`.** Python's `if my_list:` means "if not empty" — it uses Python truthiness. The converter must wrap conditions in `truthy?/1` to preserve this behavior. As an optimization, conditions that are already comparison (`Compare`) or boolean (`BoolOp`) nodes can skip the wrapping since they always produce `true`/`false`. For all other condition types (bare `Name`, `Call`, `Subscript`, etc.), the wrapping is required.

```elixir
def convert(%{"_type" => "If"} = node, ctx) do
  branches = collect_if_elif_chain(node)
  convert_to_cond(branches, ctx)
end

# Wrap condition in truthy? unless it's already a boolean-producing node
defp wrap_truthy(%{"_type" => type} = test, ctx) when type in ~w[Compare BoolOp] do
  convert(test, ctx)
end
defp wrap_truthy(test, ctx) do
  {test_ast, ctx} = convert(test, ctx)
  # truthy? is a local defp in the generated module (see §13.20),
  # so emit a local function call, NOT a remote call to Pylixir.Helpers.
  {{:truthy?, [], [test_ast]}, ctx}
end

# Collect all branches into a flat list of {test, body} pairs
defp collect_if_elif_chain(%{"_type" => "If", "test" => test, "body" => body, "orelse" => orelse}) do
  case orelse do
    [] ->
      [{test, body}]

    [%{"_type" => "If"} = elif_node] ->
      [{test, body} | collect_if_elif_chain(elif_node)]

    else_body ->
      [{test, body}, {:else, else_body}]
  end
end

# Convert to cond AST
defp convert_to_cond(branches, ctx) do
  # For a simple if with no else, emit an if expression instead of cond:
  case branches do
    [{test, body}] ->
      # Simple if, no else
      {test_ast, ctx} = wrap_truthy(test, ctx)
      {body_ast, ctx} = convert_many(body, ctx)
      {{:if, [], [test_ast, [do: body_ast]]}, ctx}

    _ ->
      # cond block
      {cond_clauses, ctx} = Enum.reduce(branches, {[], ctx}, fn
        {:else, body}, {acc, ctx} ->
          {body_ast, ctx} = convert_many(body, ctx)
          clause = {:->, [], [[true], body_ast]}
          {acc ++ [clause], ctx}

        {test, body}, {acc, ctx} ->
          {test_ast, ctx} = wrap_truthy(test, ctx)
          {body_ast, ctx} = convert_many(body, ctx)
          clause = {:->, [], [[test_ast], body_ast]}
          {acc ++ [clause], ctx}
      end)

      {{:cond, [], [[do: cond_clauses]]}, ctx}
  end
end
```

**Why `cond` over nested `if/else`:** A single code path is simpler to implement and debug. `cond` produces flat, readable output for any number of branches. For a simple `if` with no `else`, the converter still emits `if` for readability.

### 13.13 Statement-to-Expression Wrapping

In Python, `if`, `for`, and `while` are statements (no return value). In Elixir, they are expressions (always return a value). When a Python `If` statement appears where a statement is expected (not an expression context), the transpiler can emit the Elixir `if` directly — its return value will be harmlessly ignored by the `__block__` wrapper.

When a Python `If` expression appears inside another expression (e.g., `x = cond if test else other`), the `IfExp` node is used instead, which maps to Elixir's `if` as an expression naturally.

### 13.14 `return` Inside Loops

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

### 13.15 Slicing Implementation

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

### 13.16 String Concatenation Detection (MVP)

For the MVP, the `BinOp` handler uses the runtime-dispatch helper `py_add/2` whenever the `Add` operator is encountered and the operand types are not statically obvious:

```elixir
defp py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
defp py_add(a, b) when is_number(a) and is_number(b), do: a + b
defp py_add(a, b) when is_list(a) and is_list(b), do: a ++ b
defp py_add(a, b), do: a + b
```

**Static optimization:** When both operands are string `Constant` nodes, or either operand is a `Call` to `str()` (mapped to `to_string/1`), the converter emits `<>` directly without the helper. This covers the most common cases and produces cleaner output.

### 13.17 Power Operator Dispatch

The `Pow` operator in `BinOp` uses the `py_pow/2` runtime helper (see §13.20), which dispatches based on operand types. When both operands are integers with a non-negative exponent, it uses `Integer.pow/2` to preserve exact integer arithmetic. Otherwise, it falls back to `:math.pow/2`:

```elixir
def convert_pow(base_ast, %{"_type" => "Constant", "value" => exp}, ctx) when is_integer(exp) and exp >= 0 do
  {quote(do: Integer.pow(unquote(base_ast), unquote(exp))), ctx}
end

def convert_pow(base_ast, exp_ast, ctx) do
  {quote(do: py_pow(unquote(base_ast), unquote(exp_ast))), ctx}
end
```

**Note:** The static optimization for known integer literals emits `Integer.pow` directly, avoiding the helper call overhead. For runtime-determined exponents, `py_pow` handles the dispatch (see §11.23 for the precision trade-offs).

### 13.18 Formatter Pipeline

The final output pipeline must handle the `iodata` return type of `Code.format_string!/1`:

```elixir
def to_source(python_ast) do
  context = %Pylixir.Context{
    scopes: [MapSet.new()],
    known_functions: collect_function_names(python_ast["body"] || [])
  }
  {elixir_ast, _context} = convert(python_ast, context)

  elixir_ast
  |> Macro.to_string()        # returns binary string
  |> Code.format_string!()    # returns iodata (NOT binary!)
  |> IO.iodata_to_binary()    # returns binary string
end
```

Both `Macro.to_string/1` and the final `IO.iodata_to_binary/1` return binary strings. The intermediate `Code.format_string!/1` is the only step that returns iodata.

### 13.19 Tuple Swap Evaluation Order

Python evaluates the right-hand side of assignments completely before assigning. This matters for tuple swaps:

```python
a, b = b, a   # evaluates (b, a) first, then assigns
```

The transpiler must emit a tuple on the right side:

```elixir
{a, b} = {b, a}   # right side evaluated first — correct swap
```

**WRONG:** Sequential assignment (`a = b; b = a`) would set both variables to `b`'s original value. Always emit tuple assignment for tuple unpacking targets.

### 13.20 Runtime Helpers Module

The generated module includes helper functions for runtime type dispatch. These avoid the need for compile-time type inference:

```elixir
# Included in the generated TranslatedCode module:

defp truthy?(nil), do: false
defp truthy?(false), do: false
defp truthy?(0), do: false
defp truthy?(0.0), do: false
defp truthy?(""), do: false
defp truthy?([]), do: false
defp truthy?(%MapSet{} = s), do: MapSet.size(s) > 0
defp truthy?(map) when is_map(map) and map_size(map) == 0, do: false
defp truthy?(_), do: true

defp py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
defp py_add(a, b) when is_boolean(a), do: py_add(py_bool_to_int(a), b)
defp py_add(a, b) when is_boolean(b), do: py_add(a, py_bool_to_int(b))
defp py_add(a, b) when is_number(a) and is_number(b), do: a + b
defp py_add(a, b) when is_list(a) and is_list(b), do: a ++ b
defp py_add(a, b), do: a + b

defp py_mult(a, b) when is_binary(a) and is_integer(b), do: String.duplicate(a, b)
defp py_mult(a, b) when is_integer(a) and is_binary(b), do: String.duplicate(b, a)
defp py_mult(a, b) when is_list(a) and is_integer(b), do: List.duplicate(a, b) |> Enum.concat()
defp py_mult(a, b) when is_integer(a) and is_list(b), do: List.duplicate(b, a) |> Enum.concat()
defp py_mult(a, b) when is_boolean(a), do: py_mult(py_bool_to_int(a), b)
defp py_mult(a, b) when is_boolean(b), do: py_mult(a, py_bool_to_int(b))
defp py_mult(a, b), do: a * b

defp py_pow(base, exp) when is_integer(base) and is_integer(exp) and exp >= 0, do: Integer.pow(base, exp)
defp py_pow(base, exp), do: :math.pow(base, exp)

defp py_len(x) when is_list(x), do: length(x)
defp py_len(x) when is_binary(x), do: String.length(x)
defp py_len(%MapSet{} = x), do: MapSet.size(x)
defp py_len(x) when is_map(x), do: map_size(x)
defp py_len(x) when is_tuple(x), do: tuple_size(x)

defp py_getitem(collection, key) when is_list(collection), do: Enum.at(collection, key)
defp py_getitem(collection, key) when is_binary(collection), do: String.at(collection, key)
defp py_getitem(collection, key) when is_tuple(collection) and key >= 0, do: elem(collection, key)
defp py_getitem(collection, key) when is_tuple(collection), do: elem(collection, tuple_size(collection) + key)
defp py_getitem(collection, key) when is_map(collection), do: Map.fetch!(collection, key)

defp py_setitem(collection, key, value) when is_list(collection), do: List.replace_at(collection, key, value)
defp py_setitem(collection, key, value) when is_map(collection), do: Map.put(collection, key, value)

defp py_in(x, collection) when is_list(collection), do: x in collection
defp py_in(x, collection) when is_binary(collection), do: String.contains?(collection, x)
defp py_in(x, %MapSet{} = collection), do: MapSet.member?(collection, x)
defp py_in(x, collection) when is_map(collection), do: Map.has_key?(collection, x)
defp py_in(x, collection) when is_tuple(collection), do: py_in(x, Tuple.to_list(collection))
defp py_in(x, collection), do: Enum.member?(collection, x)

defp py_int(true), do: 1
defp py_int(false), do: 0
defp py_int(x) when is_float(x), do: trunc(x)
defp py_int(x) when is_integer(x), do: x
defp py_int(x) when is_binary(x), do: String.trim(x) |> String.to_integer()

defp py_float(true), do: 1.0
defp py_float(false), do: 0.0
defp py_float(x) when is_integer(x), do: x / 1
defp py_float(x) when is_float(x), do: x
defp py_float(x) when is_binary(x) do
  trimmed = String.trim(x)
  case Float.parse(trimmed) do
    {f, ""} -> f
    _ -> raise ArgumentError, "could not convert string to float: #{inspect(x)}"
  end
end

defp py_str(true), do: "True"
defp py_str(false), do: "False"
defp py_str(nil), do: "None"
defp py_str(x) when is_atom(x), do: Atom.to_string(x)
defp py_str(x) when is_list(x), do: py_repr_list(x)
defp py_str(x) when is_tuple(x), do: py_repr_tuple(x)
defp py_str(x) when is_map(x) and not is_struct(x), do: py_repr_map(x)
defp py_str(x), do: to_string(x)

# Python-style repr for compound types (used by py_str and print)
defp py_repr_list(items) do
  "[" <> Enum.map_join(items, ", ", &py_repr/1) <> "]"
end

defp py_repr_tuple(t) do
  items = Tuple.to_list(t)
  case items do
    [single] -> "(" <> py_repr(single) <> ",)"
    _ -> "(" <> Enum.map_join(items, ", ", &py_repr/1) <> ")"
  end
end

defp py_repr_map(m) do
  "{" <> Enum.map_join(m, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end) <> "}"
end

defp py_repr(x) when is_binary(x), do: "'" <> x <> "'"
defp py_repr(x), do: py_str(x)

defp py_bool_to_int(true), do: 1
defp py_bool_to_int(false), do: 0
defp py_bool_to_int(x), do: x

# s.find(sub) — returns character index or -1 (not nil)
# Uses String operations for correct Unicode character positions.
# (:binary.match/2 returns byte offsets, wrong for multi-byte UTF-8.)
defp py_str_find(s, sub) do
  case String.split(s, sub, parts: 2) do
    [_] -> -1
    [before, _rest] -> String.length(before)
  end
end

# s.count(sub) — count non-overlapping occurrences
# NOTE: empty substring is a known limitation. Python's "abc".count("")
# returns 4 (len + 1). This helper does not support empty substring.
defp py_str_count(_s, ""), do: raise(ArgumentError, "py_str_count with empty substring not supported")
defp py_str_count(s, sub), do: length(String.split(s, sub)) - 1

# list.index(x) — returns index or raises
defp py_list_index(list, x) do
  case Enum.find_index(list, fn v -> v == x end) do
    nil -> raise RuntimeError, "#{inspect(x)} is not in list"
    idx -> idx
  end
end
```

### 13.21 Nested Function Definitions (Inner `def`)

Python allows defining functions inside other functions. The inner function becomes a closure over the enclosing scope:

```python
def outer(x):
    def inner(y):
        return x + y
    return inner(5)
```

In Elixir, `defp` inside `defmodule` cannot capture outer function variables — `defp` defines a module-level function, not a closure. The converter must emit inner function definitions as anonymous functions (`fn`):

```elixir
defp outer(x) do
  inner = fn y -> x + y end
  inner.(5)
end
```

**Key implementation details:**

1. **Detection:** When a `FunctionDef` node appears inside the body of another `FunctionDef`, it is a nested function. The outer `FunctionDef` is handled normally (emits `defp`); the inner one emits an anonymous function assigned to a variable.

2. **Variable capture:** Elixir's `fn` captures variables by value at creation time. This naturally matches Python's closure semantics for most algorithmic code (where the captured variable is not mutated after the inner function is defined).

3. **Recursive inner functions:** If the inner function calls itself recursively, the anonymous function approach is more complex because the function must reference itself. Use a Y-combinator pattern or assign the function and pass itself as an argument:

```python
def outer():
    def helper(n):
        if n <= 0:
            return 0
        return n + helper(n - 1)
    return helper(10)
```

```elixir
defp outer() do
  helper = fn helper_ref, n ->
    if n <= 0 do
      0
    else
      n + helper_ref.(helper_ref, n - 1)
    end
  end
  helper.(helper, 10)
end
```

This self-referencing pattern works but is verbose. For the MVP, it is the recommended approach. A future version could detect non-recursive inner functions and use the simpler `fn` form.

4. **Scope stack update:** When entering a nested `FunctionDef`, push a new scope. The inner function's parameters and local variables go in this new scope. Variables from the outer scope are accessible (captured by the `fn` closure) but not added to the inner scope.

5. **Known functions pre-pass:** The two-pass name collection (§13.6) should NOT include nested function names — they are local bindings, not module-level functions.
