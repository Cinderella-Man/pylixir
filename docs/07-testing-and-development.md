## §14. Testing Strategy

### 14.1 Test Categories

#### 1. Unit Tests (per AST node)

Each supported AST node gets a test that verifies the `convert/2` function produces the correct Elixir AST.

```elixir
test "converts BinOp with Add operator" do
  python_ast = %{
    "_type" => "BinOp",
    "left" => %{"_type" => "Constant", "value" => 1},
    "op" => %{"_type" => "Add"},
    "right" => %{"_type" => "Constant", "value" => 2}
  }
  {result, _ctx} = Pylixir.convert(python_ast, %Pylixir.Context{scopes: [MapSet.new()]})
  assert result == {:+, [], [1, 2]}
end
```

#### 2. Integration Tests (full Python programs)

End-to-end tests that transpile a complete Python program and verify the output compiles and runs correctly.

```elixir
test "transpiles fibonacci function" do
  python_source = """
  def fib(n):
      if n <= 1:
          return n
      return fib(n - 1) + fib(n - 2)

  print(fib(10))
  """

  elixir_code = Pylixir.transpile(python_source)
  assert {:ok, _} = Code.format_string(elixir_code)
  # Optionally: capture IO and verify output
end
```

#### 3. Semantic Correctness Tests

For each edge case in §11, a test that verifies the transpiled code produces the same output as Python.

```elixir
test "floor division matches Python semantics" do
  # Python: -7 // 2 == -4
  assert Integer.floor_div(-7, 2) == -4
end

test "modulo matches Python semantics" do
  # Python: -7 % 3 == 2
  assert Integer.mod(-7, 3) == 2
end

test "string concatenation with + operator" do
  # Python: "hello" + " " + "world" == "hello world"
  assert "hello" <> " " <> "world" == "hello world"
end

test "range with negative step" do
  # Python: list(range(10, 0, -1)) == [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
  assert Enum.to_list(10..1//-1) == [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
end

test "power with float exponent" do
  # Python: 2 ** 0.5 ≈ 1.4142
  assert_in_delta :math.pow(2, 0.5), 1.4142, 0.001
end
```

#### 4. Error Handling Tests

Verify that unsupported nodes raise `UnsupportedNodeError` with descriptive messages.

```elixir
test "ClassDef raises UnsupportedNodeError" do
  python_ast = %{"_type" => "ClassDef", "name" => "Foo"}
  assert_raise Pylixir.Errors.UnsupportedNodeError, ~r/ClassDef/, fn ->
    Pylixir.convert(python_ast, %Pylixir.Context{scopes: [MapSet.new()]})
  end
end

test "Match raises UnsupportedNodeError" do
  python_ast = %{"_type" => "Match"}
  assert_raise Pylixir.Errors.UnsupportedNodeError, ~r/Match/, fn ->
    Pylixir.convert(python_ast, %Pylixir.Context{scopes: [MapSet.new()]})
  end
end
```

#### 5. Round-Trip Tests (Golden Tests)

For a corpus of Python programs, store the expected Elixir output as golden files. On each test run, transpile the Python and compare against the golden output. Any difference indicates a regression.

```
test/fixtures/
  python/
    fibonacci.py
    binary_search.py
    linked_list.py
  elixir/
    fibonacci.exs
    binary_search.exs
    linked_list.exs
```

### 14.2 Test Corpus

Start with these algorithmic programs:

1. **Fibonacci** (recursive and iterative) — tests recursion, `while`, augmented assignment
2. **Binary search** — tests `while`, `if`/`elif`/`else`, comparison chains, slicing
3. **Merge sort** — tests list slicing, recursion, `while`
4. **Stack/Queue** — tests list `append`/`pop`, mutation methods
5. **Graph BFS/DFS** — tests dict/list mutation, `while`, `for`/`in`, `dict.items()`
6. **FizzBuzz** — tests `for`/`range`, `if`/`elif`/`else`, `print`, string concatenation
7. **Two Sum** — tests dict operations, `enumerate`, `for`/`in`
8. **Palindrome check** — tests string slicing, `while`, comparison
9. **Factorial** — tests recursion, `if`, `return`
10. **Prime sieve** — tests `for`/`range`, list mutation, `if`

### 14.3 Test Runner

```elixir
# In mix.exs
defp deps do
  [
    {:jason, "~> 1.4"},
    {:mix_test_watch, "~> 1.0", only: :dev, runtime: false}
  ]
end
```

Run tests with: `mix test`

Run with coverage: `mix test --cover`

Watch mode: `mix test.watch`

---

## §15. Development Steps

| Step | Deliverable | Status |
|------|------------|--------|
| 1 | Project setup with Elixir project, Python JSON serializer, `convert/2` skeleton | **DEFERRED** |
| 2 | Literal and variable support (`Constant`, `Name`) | **DEFERRED** |
| 3 | Arithmetic operators (`BinOp`, `UnaryOp`) with string concatenation detection | **DEFERRED** |
| 4 | Boolean operators (`BoolOp`, `Compare`) with chaining | **DEFERRED** |
| 5 | Control flow (`If`, `For` with accumulator detection, `While`, `Break`, `Continue`, `Pass`) | **DEFERRED** |
| 6 | Functions (`FunctionDef`, `Return` with try/throw/catch, `Lambda`) | **DEFERRED** |
| 7 | Collections (`List`, `Tuple`, `Dict`, `ListComp`) and slicing (`Slice`) | **DEFERRED** |
| 8 | Built-in functions (mapped builtins table) including dict methods | **DEFERRED** |
| 9 | Mutation patterns (`AugAssign`, mutation methods) | **DEFERRED** |
| 10 | `Assert` and `Expr` statement wrapper | **DEFERRED** |
| 11 | Edge case testing and correctness verification | **DEFERRED** |
| 12 | Golden test corpus and regression testing | **DEFERRED** |

---

## §16. Project Structure

```
pylixir/
├── lib/
│   ├── pylixir.ex                  # Main API (to_source/1, transpile/1)
│   └── pylixir/
│       ├── context.ex              # Context struct definition
│       ├── converter.ex            # Main convert/2 dispatch
│       ├── nodes/
│       │   ├── literals.ex         # Constant, Name handlers
│       │   ├── operators.ex        # BinOp, UnaryOp, BoolOp, Compare
│       │   ├── expressions.ex      # Call, IfExp, Subscript, Slice, ListComp, Lambda
│       │   ├── statements.ex       # Assign, AugAssign, Return, If, For, While, Pass, Break, Continue, Assert, Expr
│       │   └── functions.ex        # FunctionDef, arguments, arg
│       ├── builtins.ex             # Built-in function mapping table
│       ├── scope.ex                # Scope management utilities
│       ├── helpers.ex              # Generated helper functions (py_add, truthy?, etc.)
│       ├── formatter.ex            # Elixir code formatting (Macro.to_string + Code.format_string! + IO.iodata_to_binary)
│       └── errors.ex               # UnsupportedNodeError, UndefinedNameError
├── priv/
│   └── python/
│       └── serialize.py            # Python AST serialization script
├── test/
│   ├── pylixir_test.exs            # Integration tests
│   ├── nodes/
│   │   ├── literals_test.exs
│   │   ├── operators_test.exs
│   │   ├── expressions_test.exs
│   │   ├── statements_test.exs
│   │   └── functions_test.exs
│   ├── builtins_test.exs
│   ├── edge_cases_test.exs         # §11 edge case tests
│   └── fixtures/
│       ├── python/                 # Python source files
│       └── elixir/                 # Golden Elixir output files
├── mix.exs
└── README.md
```
