## §8. Elixir AST Reference (Critical Implementation Knowledge)

> **Purpose:** This section is a consolidated reference for Elixir's AST format, written for implementers who need to construct Elixir AST programmatically. Every example shows both the Elixir source code and the corresponding AST tuple structure that `convert/2` must produce.

### 8.1 The Three-Tuple Rule

Every non-literal expression in Elixir's AST is a three-element tuple:

```elixir
{name_or_operator, metadata, arguments_or_context}
```

- **`name_or_operator`**: An atom (for variables, function calls, operators) or another tuple (for remote calls like `Module.function`)
- **`metadata`**: A keyword list, usually `[]` for generated code (line numbers are optional)
- **`arguments_or_context`**: A list of arguments (for function calls), an atom like `nil` or `Elixir` (for variables), or a keyword list (for special forms)

**Literals that represent themselves (no wrapping tuple):**
- Atoms: `:ok`, `:error`, `true`, `false`, `nil`
- Integers: `42`
- Floats: `3.14`
- Strings: `"hello"`
- Lists: `[1, 2, 3]`
- Two-element tuples: `{:a, :b}` (but 3+ element tuples use `:{}`)

### 8.2 Variables

Source: `my_var`

```elixir
{:my_var, [], nil}
#  ^name   ^meta  ^context (nil for programmatic AST)
```

The atom `:my_var` becomes the variable name. The context is `nil` when building ASTs programmatically (as opposed to `quote`, which sets it to `Elixir`).

### 8.3 Function Calls

#### Local call
Source: `sum(1, 2)`

```elixir
{:sum, [], [1, 2]}
#  ^name  ^meta  ^args as list
```

#### Remote call (Module.function)
Source: `Enum.sort(list)`

```elixir
{
  {:., [], [{:__aliases__, [], [:Enum]}, :sort]},
  #  ^dot   ^meta  ^module alias           ^function name
  [],
  [{:list, [], nil}]
#  ^args
}
```

**Pattern for remote calls:**
```elixir
{{:., [], [module_alias_ast, :function_name]}, [], [args]}
```

Where `module_alias_ast` is:
```elixir
{:__aliases__, [], [:Module, :Name]}
# For single-word modules: {:__aliases__, [], [:Enum]}
# For nested modules: {:__aliases__, [], [:MyApp, :Utils]}
```

### 8.4 Operators

#### Arithmetic
Source: `a + b`

```elixir
{:+, [], [{:a, [], nil}, {:b, [], nil}]}
```

Source: `a - b` → `{-, [], [a_ast, b_ast]}`
Source: `a * b` → `{*, [], [a_ast, b_ast]}`
Source: `a / b` → `{/, [], [a_ast, b_ast]}`

#### Comparison
Source: `a == b` → `{:==, [], [a_ast, b_ast]}`
Source: `a != b` → `{:!=, [], [a_ast, b_ast]}`
Source: `a < b`  → `{:<, [], [a_ast, b_ast]}`
Source: `a <= b` → `{:<=, [], [a_ast, b_ast]}`

#### Boolean (logical)
Source: `a && b` → `{:&&, [], [a_ast, b_ast]}`
Source: `a || b` → `{:||, [], [a_ast, b_ast]}`
Source: `!a`     → `{:!, [], [a_ast]}`

**CRITICAL: Use `&&`/`||`/`!`, NOT `and`/`or`/`not`.** See §9.7 for the full rationale. In short: Elixir's strict `and`/`or`/`not` raise `BadBooleanError` on non-booleans; `&&`/`||`/`!` accept any value, matching Python's flexibility.

#### String concatenation
Source: `a <> b` → `{:<>, [], [a_ast, b_ast]}`

This is used when the `BinOp` `Add` operator is applied to string operands. See §11.19.

#### Bitwise (requires `import Bitwise`)
Source: `a <<< b` → `{:<<<, [], [a_ast, b_ast]}`
Source: `a >>> b` → `{:>>>, [], [a_ast, b_ast]}`
Source: `a ||| b` → `{:|||, [], [a_ast, b_ast]}`
Source: `a &&& b` → `{:&&&, [], [a_ast, b_ast]}`
Source: `a ^^^ b` → `{:^^^, [], [a_ast, b_ast]}`
Source: `~~~a`    → `{:~~~, [], [a_ast]}`

### 8.5 Blocks (Multiple Statements)

When a function body or block has multiple statements, they're wrapped in `__block__`:

Source:
```elixir
x = 1
x + 2
```

```elixir
{:__block__, [], [
  {:=, [], [{:x, [], nil}, 1]},
  {:+, [], [{:x, [], nil}, 2]}
]}
```

**Important:** A single expression does NOT get wrapped in `__block__`. Only two or more statements need it.

```elixir
# Single statement: no __block__
{:=, [], [{:x, [], nil}, 1]}

# Two statements: wrapped in __block__
{:__block__, [], [
  {:=, [], [{:x, [], nil}, 1]},
  {:+, [], [{:x, [], nil}, 2]}
]}
```

### 8.6 `if` Expression

Source: `if condition do body else else_body end`

```elixir
{:if, [], [
  condition_ast,
  [do: body_ast, else: else_body_ast]
]}
```

Source: `if condition do body end` (no else)

```elixir
{:if, [], [
  condition_ast,
  [do: body_ast]
]}
```

### 8.7 `cond` Expression

Source:
```elixir
cond do
  x > 0 -> :positive
  x < 0 -> :negative
  true -> :zero
end
```

```elixir
{:cond, [], [
  [
    do: [
      {:->, [], [[{:>, [], [{:x, [], nil}, 0]}], :positive]},
      {:->, [], [[{:<, [], [{:x, [], nil}, 0]}], :negative]},
      {:->, [], [[true], :zero]}
    ]
  ]
]}
```

### 8.8 `def` and `defp`

Source: `def add(a, b) do a + b end`

```elixir
{:def, [], [
  {:add, [], [{:a, [], nil}, {:b, [], nil}]},
  [do: {:+, [], [{:a, [], nil}, {:b, [], nil}]}]
]}
```

Source: `defp helper(x) do x end`

```elixir
{:defp, [], [
  {:helper, [], [{:x, [], nil}]},
  [do: {:x, [], nil}]
]}
```

Source: `def greet(name, greeting \\ "Hello") do ... end`

```elixir
{:def, [], [
  {:greet, [], [
    {:name, [], nil},
    {:\\, [], [{:greeting, [], nil}, "Hello"]}
  ]},
  [do: body_ast]
]}
```

### 8.9 Anonymous Functions (`fn`)

Source: `fn x, acc -> x + acc end`

```elixir
{:fn, [], [
  {:->, [], [
    [{:x, [], nil}, {:acc, [], nil}],
    # ^params as a list   ^body
    {:+, [], [{:x, [], nil}, {:acc, [], nil}]}
  ]}
]}
```

**Single-clause fn with pattern matching:**
Source: `fn {a, b} -> a + b end`

```elixir
{:fn, [], [
  {:->, [], [
    [{:{}, [], [{:a, [], nil}, {:b, [], nil}]}],
    {:+, [], [{:a, [], nil}, {:b, [], nil}]}
  ]}
]}
```

Note: 2-element tuple patterns use bare `{:a, :b}` syntax. 3+ element tuple patterns use `{:{}, [], [elements...]}`.

### 8.10 Tuples (3+ elements)

Source: `{a, b, c}`

```elixir
{:{}, [], [{:a, [], nil}, {:b, [], nil}, {:c, [], nil}]}
```

Source: `{a, b}` (2-element tuple — special case, no `:{}`)

```elixir
{{:a, [], nil}, {:b, [], nil}}
```

### 8.11 Maps

Source: `%{key: value}`

```elixir
{:%{}, [], [key: {:value, [], nil}]}
```

Source: `%{"key" => value}`

```elixir
{:%{}, [], [{"key", {:value, [], nil}}]}
```

### 8.12 `try`/`catch`/`throw` (for early returns)

Source:
```elixir
try do
  Enum.reduce(list, acc, fn x, acc ->
    if x == target, do: throw({:return, acc})
    acc + x
  end)
catch
  {:return, result} -> result
end
```

```elixir
{:try, [], [
  [do: try_body_ast],
  [catch: [
    {:->, [], [
      [{:{}, [], [:return, {:result, [], nil}]}],
      {:result, [], nil}
    ]}
  ]]
]}
```

### 8.13 `Macro.to_string/1` Rendering Examples

For implementers who need to verify their AST construction, here's what `Macro.to_string/1` produces for various AST structures:

| AST | `Macro.to_string` output |
|-----|-----------------------------|
| `{:+, [], [1, 2]}` | `"1 + 2"` |
| `{:&&, [], [{:a, [], nil}, {:b, [], nil}]}` | `"a && b"` |
| `{:==, [], [{:x, [], nil}, nil]}` | `"x == nil"` |
| `{:fn, [], [{:->, [], [[{:x, [], nil}], {:+, [], [{:x, [], nil}, 1]}]}]}` | `"fn x -> x + 1 end"` |
| `{:if, [], [{:cond, [], nil}, [do: {:a, [], nil}, else: {:b, [], nil}]]}` | `"if cond, do: a, else: b"` |
| `{:__block__, [], [{:=, [], [{:x, [], nil}, 1]}, {:x, [], nil}]}` | `"x = 1\nx"` |
| `{{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [{:list, [], nil}]}` | `"Enum.sort(list)"` |

**Important gotcha:** `Code.format_string!/1` returns **iodata**, NOT a binary string. See §6.1.1 for the full explanation and correct pipeline.

**Important gotcha — parenthesization:** `Macro.to_string/1` produces syntactically valid but visually ugly code — it adds parentheses around special forms like `defmodule(Foo) do`, `def(add(a, b)) do`, etc. This is cosmetically unpleasant but harmless: `Code.format_string!/1` cleans these up automatically. Do not use `Macro.to_string/1` output directly as the final result — always pass through `Code.format_string!/1`.
