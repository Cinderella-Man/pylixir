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

test "string repetition with *" do
  # Python: "abc" * 3 == "abcabcabc"
  assert String.duplicate("abc", 3) == "abcabcabc"
end

test "list repetition with *" do
  # Python: [0] * 5 == [0, 0, 0, 0, 0]
  assert List.duplicate(0, 5) == [0, 0, 0, 0, 0]
end

test "multi-element list repetition with *" do
  # Python: [1, 2] * 3 == [1, 2, 1, 2, 1, 2]
  assert List.duplicate([1, 2], 3) |> Enum.concat() == [1, 2, 1, 2, 1, 2]
end

test "nested list repetition preserves nesting" do
  # Python: [[1, 2]] * 3 == [[1, 2], [1, 2], [1, 2]]
  assert List.duplicate([[1, 2]], 3) |> Enum.concat() == [[1, 2], [1, 2], [1, 2]]
end

test "boolean arithmetic — True + True == 2" do
  # Python: True + True == 2
  py_bool_to_int = fn true -> 1; false -> 0; x -> x end
  assert py_bool_to_int.(true) + py_bool_to_int.(true) == 2
end

test "boolean arithmetic — count increment via comparison" do
  # Python: count += (x > 0)
  py_bool_to_int = fn true -> 1; false -> 0; x -> x end
  count = 0
  count = count + py_bool_to_int.(5 > 0)
  assert count == 1
end

test "while loop returns final state" do
  # Python: x = 1; while x < 100: x = x * 2; print(x) → 128
  defmodule WhileTest do
    defp while_0(x) do
      if x < 100 do
        x = x * 2
        while_0(x)
      else
        {x}
      end
    end

    def test_while do
      {x} = while_0(1)
      x
    end
  end
  assert WhileTest.test_while() == 128
end

test "hex() outputs lowercase with prefix" do
  # Python: hex(255) == "0xff"
  assert "0x" <> String.downcase(Integer.to_string(255, 16)) == "0xff"
end

test "int() with no arguments returns 0" do
  # Python: int() == 0
  assert 0 == 0
end

test "float() with no arguments returns 0.0" do
  # Python: float() == 0.0
  assert 0.0 == 0.0
end

test "string character access with String.at" do
  # Python: "hello"[1] == "e"
  assert String.at("hello", 1) == "e"
  # Python: "hello"[-1] == "o"
  assert String.at("hello", -1) == "o"
end

test "print() with no arguments outputs empty line" do
  # Python: print() → "" + newline
  assert capture_io(fn -> IO.puts("") end) == "\n"
end

test "truthy? handles empty map and empty MapSet correctly" do
  truthy? = fn
    nil -> false
    false -> false
    0 -> false
    0.0 -> false
    "" -> false
    [] -> false
    %MapSet{} = s -> MapSet.size(s) > 0
    map when is_map(map) and map_size(map) == 0 -> false
    _ -> true
  end
  assert truthy?.(%{}) == false
  assert truthy?.(%{a: 1}) == true
  assert truthy?.(MapSet.new()) == false
  assert truthy?.(MapSet.new([1])) == true
end

test "py_int handles booleans" do
  # Python: int(True) == 1, int(False) == 0
  py_int = fn
    true -> 1
    false -> 0
    x when is_float(x) -> trunc(x)
    x when is_integer(x) -> x
    x when is_binary(x) -> String.trim(x) |> String.to_integer()
  end
  assert py_int.(true) == 1
  assert py_int.(false) == 0
end

test "py_int strips whitespace from strings" do
  # Python: int("  42  ") == 42
  assert String.trim("  42  ") |> String.to_integer() == 42
end

test "py_float handles integer-formatted strings" do
  # Python: float("3") == 3.0
  {f, ""} = Float.parse("3")
  assert f == 3.0
end

test "py_str matches Python str() for booleans and None" do
  # Python: str(True) == "True", str(False) == "False", str(None) == "None"
  py_str = fn
    true -> "True"
    false -> "False"
    nil -> "None"
    x -> to_string(x)
  end
  assert py_str.(true) == "True"
  assert py_str.(false) == "False"
  assert py_str.(nil) == "None"
  assert py_str.(42) == "42"
end

test "py_mult handles boolean operands" do
  # Python: True * 3 == 3, False * 5 == 0
  py_bool_to_int = fn true -> 1; false -> 0; x -> x end
  assert py_bool_to_int.(true) * 3 == 3
  assert py_bool_to_int.(false) * 5 == 0
end

test "py_getitem handles negative tuple indices" do
  # Python: (1, 2, 3)[-1] == 3
  t = {1, 2, 3}
  key = -1
  result = if key >= 0, do: elem(t, key), else: elem(t, tuple_size(t) + key)
  assert result == 3
end

test "py_list_index finds first occurrence" do
  # Python: [10, 20, 30].index(20) == 1
  assert Enum.find_index([10, 20, 30], fn v -> v == 20 end) == 1
end

test "string methods — lower, upper, split, join" do
  # Python: "Hello".lower() == "hello"
  assert String.downcase("Hello") == "hello"
  # Python: "hello".upper() == "HELLO"
  assert String.upcase("hello") == "HELLO"
  # Python: "a,b,c".split(",") == ["a", "b", "c"]
  assert String.split("a,b,c", ",") == ["a", "b", "c"]
  # Python: ",".join(["a", "b", "c"]) == "a,b,c"
  assert Enum.join(["a", "b", "c"], ",") == "a,b,c"
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

test "MatMult raises UnsupportedNodeError" do
  python_ast = %{
    "_type" => "BinOp",
    "left" => %{"_type" => "Name", "id" => "a"},
    "op" => %{"_type" => "MatMult"},
    "right" => %{"_type" => "Name", "id" => "b"}
  }
  assert_raise Pylixir.Errors.UnsupportedNodeError, ~r/MatMult/, fn ->
    Pylixir.convert(python_ast, %Pylixir.Context{scopes: [MapSet.new()]})
  end
end

test "math.inf raises UnsupportedNodeError" do
  # When the converter encounters math.inf, it should raise
  # (exact AST structure depends on how math.inf is represented)
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
10. **Prime sieve** — tests `for`/`range`, list mutation, `if`, list repetition (`[True] * n`)
11. **Counting sort** — tests list repetition (`[0] * (max_val + 1)`), boolean arithmetic
12. **Matrix sum** — tests nested `for` loops with shared mutation

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
| 3 | Arithmetic operators (`BinOp`, `UnaryOp`) with runtime helpers (`py_add`, `py_mult`) | **DEFERRED** |
| 4 | Boolean operators (`BoolOp`, `Compare`) with chaining and `truthy?/1` | **DEFERRED** |
| 5 | Control flow (`If` with always-cond, `For` with accumulator detection, `While` with state return, `Break`, `Continue`, `Pass`) | **DEFERRED** |
| 6 | Functions (`FunctionDef`, `Return` with try/throw/catch, `Lambda`) with two-pass name collection | **DEFERRED** |
| 7 | Collections (`List`, `Tuple`, `Dict`, `ListComp`) and slicing (`Slice`) | **DEFERRED** |
| 8 | Built-in functions (mapped builtins table) including dict methods, `py_len`, `py_in`, `py_int` | **DEFERRED** |
| 9 | Mutation patterns (`AugAssign`, mutation methods) | **DEFERRED** |
| 10 | `Assert` and `Expr` statement wrapper | **DEFERRED** |
| 11 | Edge case testing and correctness verification (§11.1–§11.29) | **DEFERRED** |
| 12 | Golden test corpus and regression testing | **DEFERRED** |

---

## §16. Project Structure

```
pylixir/
├── lib/
│   ├── pylixir.ex                  # Main API (to_source/1, transpile/1)
│   └── pylixir/
│       ├── context.ex              # Context struct definition
│       ├── converter.ex            # Main convert/2 dispatch (delegates to node modules)
│       ├── nodes/
│       │   ├── literals.ex         # Constant, Name handlers
│       │   ├── operators.ex        # BinOp, UnaryOp, BoolOp, Compare
│       │   ├── expressions.ex      # Call, IfExp, Subscript, Slice, ListComp, Lambda
│       │   ├── statements.ex       # Assign, AugAssign, Return, If, For, While, Pass, Break, Continue, Assert, Expr
│       │   └── functions.ex        # FunctionDef, arguments, arg
│       ├── builtins.ex             # Built-in function mapping table
│       ├── scope.ex                # Scope management utilities
│       ├── helpers.ex              # Runtime helpers (py_add, py_mult, py_len, py_in, py_getitem, py_int, py_float, py_str, py_bool_to_int, truthy?, py_str_find, py_str_count, py_list_index)
│       ├── formatter.ex            # Elixir code formatting (Macro.to_string + Code.format_string! + IO.iodata_to_binary)
│       └── errors.ex               # UnsupportedNodeError
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

### 16.1 Dispatch Mechanism

`converter.ex` is the central dispatcher. It receives a node map and delegates to the appropriate module based on `node["_type"]`:

```elixir
defmodule Pylixir.Converter do
  alias Pylixir.Nodes.{Literals, Operators, Expressions, Statements, Functions}

  def convert(%{"_type" => type} = node, context) do
    case type do
      t when t in ~w[Constant]                    -> Literals.convert(node, context)
      t when t in ~w[Name]                         -> Literals.convert(node, context)
      t when t in ~w[BinOp UnaryOp BoolOp Compare] -> Operators.convert(node, context)
      t when t in ~w[Call IfExp Subscript Lambda ListComp] -> Expressions.convert(node, context)
      t when t in ~w[Assign AugAssign Return If For While Pass Break Continue Assert Expr] -> Statements.convert(node, context)
      t when t in ~w[FunctionDef]                  -> Functions.convert(node, context)
      t when t in ~w[List Tuple Dict]              -> Literals.convert(node, context)
      t when t in ~w[Module]                       -> convert_module(node, context)
      _ -> raise Pylixir.Errors.UnsupportedNodeError, node_type: type
    end
  end

  def convert_many(nodes, context) do
    Enum.map_reduce(nodes, context, &convert/2)
  end

  defp convert_module(%{"_type" => "Module", "body" => body}, context) do
    context = %{context | known_functions: collect_function_names(body)}
    {stmts, context} = convert_many(body, context)
    body = [quote(do: import Bitwise)] ++ stmts
    {{:__block__, [], body}, context}
  end

  defp collect_function_names(body) do
    body
    |> Enum.filter(fn node -> node["_type"] == "FunctionDef" end)
    |> Enum.map(fn node -> node["name"] end)
    |> MapSet.new()
  end
end
```

Each node module (e.g., `Pylixir.Nodes.Operators`) has its own `convert/2` that pattern-matches on `node["_type"]` for the node types it handles. This keeps each file focused and manageable.
