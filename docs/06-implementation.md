## §13. Implementation Notes

### 13.1 Output Module

- Generated Elixir code uses `defp` for all functions (transient processing code, not library code).
- `import Bitwise` is conditionally included at the top of the module when bitwise operators are detected (`context.uses_bitwise == true`).
- The generated code ends with a main function call that processes the input.

### 13.2 The `convert/2` Function Pattern

```elixir
def convert(%{"_type" => "Module", "body" => body}, %Context{} = context) do
  {stmts, context} = convert_many(body, context)
  helpers = context.pending_helpers
  bitwise_import = if context.uses_bitwise, do: [quote do: import Bitwise], else: []
  body = bitwise_import ++ helpers ++ stmts
  {:__block__, [], body}
end
```

**Pattern:** Match on the `_type` field. Return `{elixir_ast, updated_context}`.

### 13.3 String-Binary Equivalence

In Elixir, strings ARE binaries. `"hello" == <<104, 101, 108, 108, 111>>`. This means Python code that treats strings as byte arrays (indexing, slicing) does NOT translate directly. Elixir strings are UTF-8 encoded, so `String.at("hello", 0)` returns `"h"`, but `"hello"[0]` in Python returns `"h"` as well (Python 3 strings are also Unicode). The key difference is that Elixir's `String.length/1` counts grapheme clusters while Python's `len()` counts code points — these differ for some Unicode characters.

**Recommendation:** Use `String.at/2` for character access and `String.length/1` for length. Document that multi-codepoint grapheme clusters may behave differently.

### 13.4 Global Variable Pattern

For script-style code with module-level mutable variables, the transpiler wraps the entire module in a module with `Agent`-based state:

```elixir
defmodule TranslatedCode do
  use Agent

  def start_link do
    Agent.start_link(fn -> %{"x" => 0, "counter" => 0} end, name: __MODULE__)
  end

  defp get(var) do
    Agent.get(__MODULE__, &Map.get(&1, var))
  end

  defp set(var, value) do
    Agent.update(__MODULE__, &Map.put(&1, var, value))
  end

  def run do
    set("x", 10)
    set("counter", 0)
    # ... rest of code using get("x") and set("x", new_value)
  end
end
```

**Alternative:** For better performance, use a `GenServer` or process dictionary. The transpiler should default to `Agent` for simplicity.

**Alternative:** For simpler scripts without deeply nested mutation, use the `throw`/`catch` pattern with variable rebinding:

```elixir
def run do
  x = 0
  try do
    Enum.each(1..10, fn i ->
      x = x + i  # This rebinding is local to the fn — WON'T affect outer x!
    end)
  catch
    _ -> :ok
  end
  IO.puts(x)  # Still 0 — the fn's rebinding was local
end
```

This is why `Agent` is necessary for cross-scope mutation. The transpiler must detect when a variable is mutated across scopes and use `Agent` for those variables.

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
defmodule Py2Ex.Errors.UnsupportedNodeError do
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

defmodule Py2Ex.Errors.UndefinedNameError do
  defexception [:message, :name]

  @impl true
  def exception(opts) do
    name = Keyword.fetch!(opts, :name)
    %__MODULE__{message: "Undefined name: #{name}", name: name}
  end
end
```

### 13.7 `while` Loop Implementation Detail

The `while` loop uses `try`/`throw`/`catch` for `break` and recursive calls for `continue`:

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
    if x == 5, do: throw(:continue)  # Skip to next iteration
    if x == 8, do: throw(:break)      # Exit loop
    IO.puts(to_string(x))
    while_0(x)  # Recurse with updated state
  else
    :ok
  end
end

try do
  while_0(0)
catch
  :break -> :ok
  :continue -> :ok  # This won't actually be reached in this pattern
end
```

**Refined pattern with proper continue handling:**

```elixir
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

### 13.8 Comparison Chain Conversion

For `Compare` nodes with multiple operators, generate an `&&` chain:

```elixir
def convert(%{"_type" => "Compare", "left" => left, "ops" => ops, "comparators" => comparators}, ctx) do
  {left_ast, ctx} = convert(left, ctx)
  pairs = Enum.zip(ops, comparators)
  {comparisons, ctx} = Enum.reduce(pairs, {[], ctx}, fn {op, comp}, {acc, ctx} ->
    {op_ast, ctx} = convert(op, ctx)
    {comp_ast, ctx} = convert(comp, ctx)
    comparison = {op_ast, [], [left_ast, comp_ast]}
    {[comparison | acc], ctx}
  end)
  comparisons = Enum.reverse(comparisons)
  # Chain with &&
  result = Enum.reduce(comparisons, fn a, b -> {:&&, [], [a, b]} end)
  {result, ctx}
end
```

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
  "Is"    => :===,
  "IsNot" => :!==,
  "In"    => :in,
  "NotIn" => :not_in  # special handling: negate the :in result
}
```

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

When a Python function contains a `return` statement inside a `for` or `while` loop, the translation is complex because Elixir's `for`/comprehension cannot "return" from the enclosing function.

**Solution:** Use `try`/`throw`/`catch`:

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

**Important:** The `return` value is wrapped in `{:return, value}` to distinguish it from other throws. The `catch` clause unwraps it.

**For nested loops:** The `try`/`catch` must be at the function level, not inside the loop. The converter must detect `Return` nodes inside loops and emit the `try` wrapper around the entire function body.
