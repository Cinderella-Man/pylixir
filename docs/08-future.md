## §17. Future Enhancements

After the core transpiler is functional, these enhancements can be considered:

### 17.1 String Similarity

Python strings use Levenshtein distance for fuzzy matching. For candidate sorting by string similarity:

```elixir
# Option 1: Pure Elixir (no dependencies)
defp string_similarity(a, b) do
  # Implement Levenshtein distance in pure Elixir
  # O(n*m) dynamic programming
end

# Option 2: External library
# {:jaro_elixir, "~> 0.1"}  — provides Jaro-Winkler distance
```

### 17.2 Direct Python-to-Elixir AST Bridge

Replace the Python process + JSON pipeline with a direct NIF or port-based bridge:

```elixir
# Python AST → Elixir Term (no JSON serialization overhead)
# Use Zigler or Rustler for a NIF that calls Python's ast module directly
```

### 17.3 Extended Type Inference

Track variable types through the context struct to enable more precise translations:

- `Enum.at(x, i)` vs `Map.get(x, key)` — if we know `x` is a list, use `Enum.at`; if dict, use `Map.get`
- `x in items` — if we know `items` is a `MapSet`, use `MapSet.member?`
- `len(x)` — if we know `x` is a string, use `String.length`; if list, use `length`

### 17.4 Mypy/Type Annotation Integration

Use Python's `typing` module annotations to inform type inference:

```python
def fibonacci(n: int) -> int:
    ...

items: list[int] = [1, 2, 3]
```

The transpiler could read `annotation` fields from the AST to determine types and generate more precise Elixir code.

### 17.5 Class Transpilation (Experimental)

For simple Python classes with only `__init__` and methods:

```python
class Stack:
    def __init__(self):
        self.items = []

    def push(self, item):
        self.items.append(item)

    def pop(self):
        return self.items.pop()
```

Could be transpiled to:

```elixir
defmodule Stack do
  defstruct items: []

  def new, do: %Stack{items: []}

  def push(%Stack{items: items} = stack, item) do
    %{stack | items: items ++ [item]}
  end

  def pop(%Stack{items: items} = stack) do
    {hd(items), %{stack | items: tl(items)}}
  end
end
```

This is a significant undertaking and should be considered a separate phase.

### 17.6 Async/Concurrency Mapping

Python's `async`/`await` could potentially be mapped to Elixir's `Task` module:

```python
async def fetch_data(url):
    response = await aiohttp.get(url)
    return response.json()
```

```elixir
defp fetch_data(url) do
  Task.async(fn -> HTTPClient.get(url) end)
  |> Task.await()
end
```

### 17.7 Generator Expression Support

Python's generator expressions could be mapped to Elixir's `Stream` module:

```python
gen = (x * 2 for x in items if x > 0)
```

```elixir
gen = items |> Stream.filter(&(&1 > 0)) |> Stream.map(&(&1 * 2))
```

---
