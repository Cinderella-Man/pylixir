
## §20. References

- **Python AST documentation**: https://docs.python.org/3/library/ast.html
- **Python AST JSON format**: https://greentreesnakes.readthedocs.io/
- **Elixir AST documentation**: https://hexdocs.pm/elixir/Macro.html
- **Elixir `Code.format_string!/1`**: https://hexdocs.pm/elixir/Code.html#format_string!/1
- **`python3 -m ast` documentation**: https://docs.python.org/3/library/ast.html#ast.dump
- **Elixir `Bitwise` module**: https://hexdocs.pm/elixir/Bitwise.html
- **Elixir `Integer.floor_div/2`**: https://hexdocs.pm/elixir/Integer.html#floor_div/2
- **Elixir `Integer.mod/2`**: https://hexdocs.pm/elixir/Integer.html#mod/2

---

## §21. Glossary of Elixir Terms for Python Developers

This glossary explains Elixir-specific terms that appear throughout this document, for readers who are primarily Python developers.

| Elixir Term | Explanation |
|---|---|
| **AST** | Abstract Syntax Tree. In Elixir, the AST is a nested structure of three-tuples `{atom, metadata, args}`. See §8. |
| **Atom** | A constant whose name is its value. Like Python's interned strings. `:hello` is an atom; `true` and `false` are atoms. |
| **Binary** | A sequence of bytes. In Elixir, strings ARE binaries. `<<104, 101, 108, 108, 111>>` == `"hello"`. |
| **Keyword list** | A list of `{atom, value}` tuples. Like Python's `**kwargs`. `[key: "value"]` is shorthand for `[{:key, "value"}]`. |
| **Map** | A key-value data structure. Like Python's `dict`. `%{"key" => "value"}` or `%{key: "value"}`. |
| **MapSet** | A set implementation backed by a map. Like Python's `set`. `MapSet.new([1, 2, 3])`. |
| **Pattern matching** | Elixir's core feature for destructuring data. `{:ok, value} = {:ok, 42}` binds `value` to `42`. |
| **Pin operator** | `^` — used to match against an existing variable's value instead of rebinding. `^x = 42` asserts `x` is already `42`. |
| **Rebinding** | In Elixir, variables can be "reassigned" (`x = 1; x = 2`). This creates a new binding, not mutation. |
| **Three-tuple** | A tuple with exactly 3 elements: `{a, b, c}`. The fundamental unit of Elixir's AST. |
| **Tuple** | An ordered collection of fixed size. `{1, "hello", :ok}`. Like Python's `tuple`. |
| **`defp`** | Define a private function (module-internal). Like Python's function without `__all__` export. |
| **`def`** | Define a public function. |
| **`fn`** | Anonymous function. Like Python's `lambda`. `fn x -> x + 1 end`. |
| **`quote`** | Returns the AST of an expression without evaluating it. `quote do: 1 + 2` returns `{:+, [], [1, 2]}`. |
| **`unquote`** | Inside `quote`, evaluates an expression and splices the result into the AST. |
| **Special form** | AST node that cannot be implemented as a macro. Examples: `fn`, `case`, `try`, `receive`. |
| **`__block__`** | The AST representation of a block of expressions. `{:__block__, [], [expr1, expr2, ...]}`. |
| **`__aliases__`** | The AST representation of a module alias. `{:__aliases__, [:alias, Foo]}`. |
| **`Code.format_string!/1`** | Formats Elixir source code. Returns **iodata** (not binary). Use `IO.iodata_to_binary/1` to get a string. |
| **iodata** | A list of binaries and characters for efficient IO. Not the same as a binary/string. |
| **`Macro.to_string/1`** | Converts an Elixir AST back to source code string. Useful for debugging. |
| **`Agent`** | A simple state-holding process. Used for mutable variable simulation. |
| **NIF** | Native Implemented Function. A way to call C/Rust code from Elixir. |
| **Port** | A mechanism for communicating with external OS processes. |

