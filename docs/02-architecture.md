## §6. Architecture and Pipeline

### 6.1 Pipeline Overview

```
Input map
  → Pylixir.Converter.convert/2 (recursive dispatch on "_type", threads context)
  → Elixir AST (tuples)
  → Macro.to_string/1 (→ binary string)
  → Code.format_string!/1 (→ iodata, NOT a binary!)
  → IO.iodata_to_binary/1 (→ final binary string)
```

**CRITICAL CORRECTION (v4→v5):** `Code.format_string!/1` returns `iodata()`, NOT a binary string. The pipeline MUST end with `IO.iodata_to_binary/1`. See §6.1.1.

#### 6.1.1 The `iodata` Gotcha

`Code.format_string!/1` returns `iodata()` (deeply nested lists of binaries and integers), NOT a flat binary string. `Macro.to_string/1` returns a binary string directly — this has always been the case. Calling `IO.puts/1` on iodata works fine (IO functions accept iodata), but string operations like `String.length/1`, `String.contains?/2`, or pattern matching will fail or produce wrong results on iodata.

```elixir
# CORRECT pipeline:
ast
|> Macro.to_string()        # returns binary string
|> Code.format_string!()    # returns iodata (NOT binary!)
|> IO.iodata_to_binary()    # returns binary string ← THIS STEP IS REQUIRED

# WRONG:
ast
|> Macro.to_string()
|> Code.format_string!()
# result is iodata, NOT a string — String operations will fail!
```

#### 6.1.2 What Does `convert/2` Do?

`convert/2` is the core function. It takes a Python AST node (an Elixir map with a `"_type"` key) and a context struct, and returns a tuple `{elixir_ast, updated_context}`.

- It pattern-matches on `node["_type"]` (e.g., `"BinOp"`, `"If"`, `"FunctionDef"`)
- It recursively calls itself on child nodes
- Each node type has its own function clause (or set of clauses for complex types)
- There is no intermediate representation, no multi-pass compilation, no optimization
- One recursive walk, one output

The function signature:

```elixir
@spec convert(node :: map(), context :: Pylixir.Context.t()) :: {Macro.t(), Pylixir.Context.t()}
def convert(%{"_type" => type} = node, context) do
  # dispatch to type-specific clause
end
```

### 6.2 Why Elixir AST as Intermediate?

Instead of building strings directly, the library builds Elixir AST tuples (the same format `quote` produces). Benefits:

- `Macro.to_string/1` handles operator precedence, `do/end` blocks, parentheses — things that are error-prone with string concatenation.
- `Code.format_string!/1` applies `mix format` rules automatically.
- `Code.eval_quoted/2` can evaluate the AST directly for testing.
- The AST is composable — build small pieces, nest them naturally.

### 6.3 Python AST Reference (Critical Implementation Knowledge)

Understanding the Python AST format is essential. This is what the library consumes. Every Python AST node has a `"_type"` field identifying the node kind, plus node-specific child fields. The Python ASDL grammar defines the canonical structure. Below is the reference for all supported node types.

**Notation:** `expr` means a single expression node (a map). `expr*` means a list of expression nodes. `expr?` means an optional expression node (may be `nil`/`null`). `identifier` is a string. `int` is an integer. `constant` is a Python literal value.

#### 6.3.1 Root Nodes

**`Module(body: stmt*)`** — The top-level wrapper. `body` is a list of statement nodes.

#### 6.3.2 Literals

**`Constant(value: constant, kind: string?)`** — All literal values in Python 3.8+. `value` can be `int`, `float`, `str`, `bool`, `None`, `bytes`, `complex`, or `Ellipsis`. After JSON serialization and `Jason.decode!/1`, Python's `True`/`False`/`None` become Elixir's `true`/`false`/`nil`. The `kind` field is `"u"` for `u"..."` string literals, `nil` otherwise. **Note:** The `kind` field is still present in the Python AST grammar through Python 3.14, but is only ever set to `"u"` for u-prefixed strings. In practice, `u"..."` is rare in modern Python 3 code. The converter should treat it as optional and default to `nil` when absent.

```elixir
# Python: 42       → %{"_type" => "Constant", "value" => 42}
# Python: "hello"  → %{"_type" => "Constant", "value" => "hello"}
# Python: True     → %{"_type" => "Constant", "value" => true}
# Python: None     → %{"_type" => "Constant", "value" => nil}
# Python: 3.14     → %{"_type" => "Constant", "value" => 3.14}
```

**Gotcha — complex numbers and bytes:** Python `Constant` can hold complex numbers (`3+4j`) and bytes (`b"hello"`). These should raise `UnsupportedNodeError`. **Serialization caveat:** JSON has no native complex number type, so the serialized form depends entirely on the `ast2json` implementation used — some will produce a dict with `real`/`imag` keys, some will produce a string representation, some will error. Bare imaginary literals like `4j` are `Constant(value=4j)` in the AST. Compound expressions like `3+4j` appear as `BinOp(Constant(3), Add, Constant(4j))`. Detection heuristic: check if the JSON value is a map/object (for dict-serialized complex) or if the `kind` field or value type doesn't match any expected type (int, float, str, bool, None). Test with your chosen serializer.

**Gotcha — float vs integer:** JSON does not distinguish between `1` and `1.0` in all cases. Python's AST does. After `Jason.decode!`, Elixir will have the correct type, so this should be fine. But test it.

#### 6.3.3 Variables

**`Name(id: identifier, ctx: expr_context)`** — A variable reference. `id` is the name as a string. `ctx` is `Load`, `Store`, or `Del` indicating whether the variable is being read, assigned to, or deleted.

```elixir
# Python: my_var (being read)
%{"_type" => "Name", "id" => "my_var", "ctx" => %{"_type" => "Load"}}

# Python: my_var (being assigned to, e.g., left side of =)
%{"_type" => "Name", "id" => "my_var", "ctx" => %{"_type" => "Store"}}
```

**`Starred(value: expr, ctx: expr_context)`** — A `*var` unpacking reference. `value` is typically a `Name` node. Used in assignment targets (`a, *b = [1,2,3]`) and function call arguments (`fn(*args)`).

```elixir
# Python: a, *b = items
# The Assign target is a Tuple containing [Name("a"), Starred(Name("b"))]
```

#### 6.3.4 Collections

**`List(elts: expr*, ctx: expr_context)`** — A list literal. `elts` is a list of element expression nodes. `ctx` is `Store` when the list is an assignment target (e.g., `[a, b] = [1, 2]`), `Load` otherwise.

**`Tuple(elts: expr*, ctx: expr_context)`** — A tuple literal. Same structure as `List`. `ctx` is `Store` when used as an assignment target (e.g., `a, b = 1, 2` creates a `Tuple` target).

**`Dict(keys: expr?*, values: expr*)`** — A dictionary literal. `keys` and `values` are parallel lists. When dictionary unpacking is used (`{**d}`), the corresponding `keys` entry is `nil`/`null` and the expression goes in `values`.

```elixir
# Python: {"a": 1, "b": 2}
%{
  "_type" => "Dict",
  "keys" => [
    %{"_type" => "Constant", "value" => "a"},
    %{"_type" => "Constant", "value" => "b"}
  ],
  "values" => [
    %{"_type" => "Constant", "value" => 1},
    %{"_type" => "Constant", "value" => 2}
  ]
}
```

#### 6.3.5 Operators (Never Standalone)

Operators are child nodes of `BinOp`, `UnaryOp`, `BoolOp`, and `Compare`. They never appear as standalone AST nodes. Each is a simple node with only `"_type"` and no other fields.

**Binary operators** (used by `BinOp`):
`Add`, `Sub`, `Mult`, `Div`, `FloorDiv`, `Mod`, `Pow`, `LShift`, `RShift`, `BitOr`, `BitXor`, `BitAnd`, `MatMult`

**Unary operators** (used by `UnaryOp`):
`UAdd`, `USub`, `Not`, `Invert`

**Boolean operators** (used by `BoolOp`):
`And`, `Or`

**Comparison operators** (used by `Compare`):
`Eq`, `NotEq`, `Lt`, `LtE`, `Gt`, `GtE`, `Is`, `IsNot`, `In`, `NotIn`

**Important:** These are four distinct operator categories used by four different expression node types. `And`/`Or` belong to `BoolOp` (which uses a `values` list), NOT to `BinOp` (which uses `left`/`right`). `In`/`NotIn`/`Is`/`IsNot` belong to `Compare`, NOT to `BinOp`. The operator lookup map is shared for convenience, but dispatch must respect which expression node type uses which operator category.

#### 6.3.6 Expressions

**`BinOp(left: expr, op: operator, right: expr)`** — A binary operation. `left` and `right` are expression nodes. `op` is one of the binary operator nodes (`Add`, `Sub`, etc.).

```elixir
# Python: a + b
%{
  "_type" => "BinOp",
  "left" => %{"_type" => "Name", "id" => "a", "ctx" => %{"_type" => "Load"}},
  "op" => %{"_type" => "Add"},
  "right" => %{"_type" => "Name", "id" => "b", "ctx" => %{"_type" => "Load"}}
}
```

**`UnaryOp(op: unaryop, operand: expr)`** — A unary operation. `op` is `UAdd`, `USub`, `Not`, or `Invert`. `operand` is the expression being operated on.

```elixir
# Python: -x
%{
  "_type" => "UnaryOp",
  "op" => %{"_type" => "USub"},
  "operand" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Load"}}
}
```

**`BoolOp(op: boolop, values: expr*)`** — A boolean operation (`and`/`or`). **Critically different from `BinOp`**: uses a `values` list, NOT `left`/`right`. Consecutive operations with the same operator are collapsed: `a and b and c` produces one `BoolOp` with three `values`, not two nested `BoolOp` nodes.

```elixir
# Python: a and b and c
%{
  "_type" => "BoolOp",
  "op" => %{"_type" => "And"},
  "values" => [
    %{"_type" => "Name", "id" => "a", "ctx" => %{"_type" => "Load"}},
    %{"_type" => "Name", "id" => "b", "ctx" => %{"_type" => "Load"}},
    %{"_type" => "Name", "id" => "c", "ctx" => %{"_type" => "Load"}}
  ]
}
```

**Conversion:** Fold the `values` list into nested `&&`/`||` expressions: `a and b and c` → `{:&&, [], [{:&&, [], [a, b]}, c]}`. **Use `&&`/`||`, not `and`/`or`** — see §9.6 and §11.

**`Compare(left: expr, ops: cmpop*, comparators: expr*)`** — A comparison of two or more values. `left` is the first value, `ops` is a list of comparison operator nodes, `comparators` is a list of the remaining values. `ops` and `comparators` are always the same length.

```elixir
# Python: a < b < c (chained comparison)
%{
  "_type" => "Compare",
  "left" => %{"_type" => "Name", "id" => "a", "ctx" => %{"_type" => "Load"}},
  "ops" => [%{"_type" => "Lt"}, %{"_type" => "Lt"}],
  "comparators" => [
    %{"_type" => "Name", "id" => "b", "ctx" => %{"_type" => "Load"}},
    %{"_type" => "Name", "id" => "c", "ctx" => %{"_type" => "Load"}}
  ]
}
```

**Conversion:** For a single comparison (one op), produce `{:op, [], [left, right]}`. For chained comparisons, expand to a `&&` chain: `a < b && b < c`. (Use `&&` not `and` — see §11.)

**`Call(func: expr, args: expr*, keywords: keyword*)`** — A function call. `func` is the function being called (usually a `Name` or `Attribute` node). `args` is a list of positional arguments. `keywords` is a list of `keyword` nodes for named arguments.

```elixir
# Python: sorted(items, key=lambda x: x[0])
%{
  "_type" => "Call",
  "func" => %{"_type" => "Name", "id" => "sorted", "ctx" => %{"_type" => "Load"}},
  "args" => [%{"_type" => "Name", "id" => "items", "ctx" => %{"_type" => "Load"}}],
  "keywords" => [
    %{
      "_type" => "keyword",
      "arg" => "key",
      "value" => %{"_type" => "Lambda", ...}
    }
  ]
}
```

**`keyword(arg: identifier?, value: expr)`** — A keyword argument. `arg` is the parameter name as a string, or `nil`/`null` for `**kwargs` unpacking.

**`IfExp(test: expr, body: expr, orelse: expr)`** — A ternary expression (`value if condition else other`). Each field is a single expression node. **Note the Python syntax ordering vs AST ordering**: Python syntax is `body if test else orelse` (value first, then condition), but the AST stores fields in logical order: `test` first, then `body`, then `orelse`.

```elixir
# Python: x if condition else y
%{
  "_type" => "IfExp",
  "test" => %{"_type" => "Name", "id" => "condition", "ctx" => %{"_type" => "Load"}},
  "body" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Load"}},
  "orelse" => %{"_type" => "Name", "id" => "y", "ctx" => %{"_type" => "Load"}}
}
```

**`Attribute(value: expr, attr: identifier, ctx: expr_context)`** — Attribute access (e.g., `obj.method`). `value` is the object expression, `attr` is the attribute name as a bare string, `ctx` is `Load`/`Store`/`Del`.

```elixir
# Python: s.lower()  — the Call's func is an Attribute node
# Call.func = %{"_type" => "Attribute", "value" => Name("s"), "attr" => "lower", "ctx" => Load}
```

**`Subscript(value: expr, slice: expr, ctx: expr_context)`** — Subscript access (e.g., `x[0]`, `x[1:3]`). `value` is the object being subscripted, `slice` is the index/key/slice expression, `ctx` is `Load`/`Store`/`Del`.

```elixir
# Python: x[0]
%{
  "_type" => "Subscript",
  "value" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Load"}},
  "slice" => %{"_type" => "Constant", "value" => 0},
  "ctx" => %{"_type" => "Load"}
}
```

**`Slice(lower: expr?, upper: expr?, step: expr?)`** — A slice object (`lower:upper:step`). All three fields are optional. Appears only inside `Subscript.slice`.

```elixir
# Python: x[1:3]
# Subscript.slice = %{"_type" => "Slice", "lower" => Constant(1), "upper" => Constant(3), "step" => nil}

# Python: x[::2]
# Subscript.slice = %{"_type" => "Slice", "lower" => nil, "upper" => nil, "step" => Constant(2)}
```

**`Lambda(args: arguments, body: expr)`** — An anonymous function. `args` uses the same `arguments` node as `FunctionDef`. `body` is a **single expression** (not a statement list like `FunctionDef`).

```elixir
# Python: lambda x, y: x + y
%{
  "_type" => "Lambda",
  "args" => %{"_type" => "arguments", "args" => [%{"_type" => "arg", "arg" => "x"}, ...], ...},
  "body" => %{"_type" => "BinOp", "left" => Name("x"), "op" => Mult, "right" => Name("y")}
}
```

**`ListComp(elt: expr, generators: comprehension*)`** — A list comprehension. `elt` is the element expression evaluated for each iteration. `generators` is a list of `comprehension` nodes.

```elixir
# Python: [x * 2 for x in items if x > 0]
%{
  "_type" => "ListComp",
  "elt" => %{"_type" => "BinOp", "left" => Name("x"), "op" => Mult, "right" => Constant(2)},
  "generators" => [
    %{
      "_type" => "comprehension",
      "target" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Store"}},
      "iter" => %{"_type" => "Name", "id" => "items", "ctx" => %{"_type" => "Load"}},
      "ifs" => [
        %{"_type" => "Compare", "left" => Name("x"), "ops" => [Gt], "comparators" => [Constant(0)]}
      ],
      "is_async" => 0
    }
  ]
}
```

**`comprehension(target: expr, iter: expr, ifs: expr*, is_async: int)`** — One `for` clause in a comprehension. `target` is the loop variable (typically `Name` or `Tuple`), `iter` is the iterable, `ifs` is a list of filter expressions (each `for` clause can have multiple `if` filters). `is_async` is 0 or 1. A `ListComp` can have multiple `comprehension` nodes for nested loops.

**`NamedExpr(target: expr, value: expr)`** — The walrus operator (`:=`). `target` is a `Name` node, `value` is any expression. This library raises `UnsupportedNodeError` for this node.

#### 6.3.7 Statements

**`Assign(targets: expr*, value: expr)`** — An assignment statement. **`targets` is a list** (plural), not a single target. Multiple targets means `a = b = 5` — one `Assign` with `targets: [Name("a"), Name("b")]` and `value: Constant(5)`. Tuple unpacking is represented by a `Tuple` node inside `targets`.

```elixir
# Python: a = b = 5
%{
  "_type" => "Assign",
  "targets" => [
    %{"_type" => "Name", "id" => "a", "ctx" => %{"_type" => "Store"}},
    %{"_type" => "Name", "id" => "b", "ctx" => %{"_type" => "Store"}}
  ],
  "value" => %{"_type" => "Constant", "value" => 5}
}

# Python: a, b = fn()
%{
  "_type" => "Assign",
  "targets" => [
    %{
      "_type" => "Tuple",
      "elts" => [Name("a", Store), Name("b", Store)],
      "ctx" => %{"_type" => "Store"}
    }
  ],
  "value" => %{"_type" => "Call", ...}
}
```

**Conversion for multiple targets:** Python evaluates the value once, then assigns to each target **left-to-right**. `a = b = 5` → `a = 5; b = 5`. Both targets receive the same value. For simple values the order is irrelevant, but for expressions with side effects (e.g., subscript targets involving function calls), left-to-right evaluation order matters. The generated Elixir should assign the evaluated value to each target in left-to-right order.

**`AugAssign(target: expr, op: operator, value: expr)`** — Augmented assignment (e.g., `a += 1`). `target` is a **single** node (unlike `Assign`). `op` is the operator (e.g., `Add`). `value` is the right-hand side.

```elixir
# Python: x += 2
%{
  "_type" => "AugAssign",
  "target" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Store"}},
  "op" => %{"_type" => "Add"},
  "value" => %{"_type" => "Constant", "value" => 2}
}
```

**`Return(value: expr?)`** — A return statement. `value` is optional (bare `return` has `value: nil`).

**`Expr(value: expr)`** — An expression used as a statement. Wraps function calls, method calls, or any expression whose return value is discarded. This is the node where mutation-method detection happens: `list.append(x)` appears as `Expr(value=Call(Attribute(Name("list"), "append"), [Name("x")]))`.

**Conversion:** When the wrapped expression is a method call that mutates in-place (e.g., `list.append(x)`), convert to a reassignment: `list = list ++ [x]`. See §13.

**`If(test: expr, body: stmt*, orelse: stmt*)`** — An if statement. `test` is the condition, `body` is a list of statements for the true branch, `orelse` is a list for the else/elif branch. Python represents `elif` as a nested `If` inside `orelse`: if `orelse` contains exactly one `If` node, that's an `elif`.

```elixir
# Python: if a: ... elif b: ... else: ...
%{
  "_type" => "If",
  "test" => a,
  "body" => [...],
  "orelse" => [
    %{
      "_type" => "If",
      "test" => b,
      "body" => [...],
      "orelse" => [...]   # The else branch
    }
  ]
}
```

**`For(target: expr, iter: expr, body: stmt*, orelse: stmt*)`** — A for loop. `target` is the loop variable (often a `Name`, or a `Tuple` for unpacking). `iter` is the iterable. `body` is the loop body. `orelse` is executed if the loop completes without `break` (the `for`/`else` construct). This library raises `UnsupportedNodeError` if `orelse` is non-empty.

```elixir
# Python: for x in items: ...
%{
  "_type" => "For",
  "target" => %{"_type" => "Name", "id" => "x", "ctx" => %{"_type" => "Store"}},
  "iter" => %{"_type" => "Name", "id" => "items", "ctx" => %{"_type" => "Load"}},
  "body" => [...],
  "orelse" => []
}
```

**`While(test: expr, body: stmt*, orelse: stmt*)`** — A while loop. `test` is the loop condition. `body` is the loop body. `orelse` is executed if the loop terminates normally without `break` (the `while`/`else` construct). This library raises `UnsupportedNodeError` if `orelse` is non-empty.

**`Pass`** — A no-op statement. No fields.

**`Break`** — Break out of a loop. No fields.

**`Continue`** — Continue to next loop iteration. No fields.

**`Assert(test: expr, msg: expr?)`** — An assertion. `test` is the condition, `msg` is an optional failure message expression.

#### 6.3.8 Function and Class Definitions

**`FunctionDef(name: identifier, args: arguments, body: stmt*, decorator_list: expr*, returns: expr?, type_params: type_param*)`** — A function definition. `name` is the function name. `args` is an `arguments` node. `body` is a list of statements. `decorator_list` is a list of decorator expressions. `returns` is the optional return type annotation (ignored by this library). `type_params` (Python 3.12+ only) is a list of type parameter nodes (ignored). **Note:** `type_params` does not exist in Python 3.8–3.11 ASTs. The converter should treat this field as optional and default to `[]` when absent.

**`arguments(posonlyargs: arg*, args: arg*, vararg: arg?, kwonlyargs: arg*, kw_defaults: expr?*, kwarg: arg?, defaults: expr*)`** — Function arguments. `posonlyargs` are positional-only parameters (before `/`). `args` are regular parameters. `vararg` is the `*args` parameter (or `nil`). `kwonlyargs` are keyword-only parameters (after `*`). `kw_defaults` parallels `kwonlyargs` — `nil` entries mean required. `kwarg` is the `**kwargs` parameter (or `nil`). `defaults` is a list of default values for the last N `args` (and `posonlyargs`) parameters.

**`arg(arg: identifier, annotation: expr?)`** — A single argument. `arg` is the parameter name. `annotation` is the type annotation (ignored).

#### 6.3.9 Context Nodes

**`Load`, `Store`, `Del`** — These context markers appear in the `ctx` field of `Name`, `Attribute`, `Subscript`, `Starred`, `List`, and `Tuple`. They indicate whether the node is being read (`Load`), assigned to (`Store`), or deleted (`Del`). The converter generally ignores `ctx` — context is determined structurally by the parent node.

#### 6.3.10 Python AST Version Variations

The Python AST format is not stable across versions. While this library targets "Python 3.8+," the AST shape varies:

| Feature | Python 3.8–3.9 | Python 3.10–3.11 | Python 3.12+ |
|---|---|---|---|
| `Constant.kind` field | Present (`"u"` or `nil`) | Present (`"u"` or `nil`) | Present (still in grammar) |
| `FunctionDef.type_params` | **Does not exist** | **Does not exist** | Present (list of type parameter nodes) |
| Old literal nodes (`Num`, `Str`, `Bytes`, `NameConstant`, `Ellipsis`) | Deprecated but still produced by some tools | Deprecated but still produced by some tools | Emit `DeprecationWarning` (3.12–3.13); **removed in 3.14** |
| `Match` statement | Does not exist | Present (Python 3.10+, PEP 634) | Present |

**The converter should treat version-dependent fields as optional.** Use `Map.get(node, "type_params", [])` rather than `node["type_params"]` to avoid `KeyError` on pre-3.12 ASTs. Similarly, `Map.get(node, "kind", nil)` for `Constant.kind`.

**Serializer variations:** The JSON representation of the Python AST depends on the serializer used (`ast2json`, `ast.dump` with custom serialization, etc.). Key areas where serializers diverge: representation of complex numbers (no JSON type exists), representation of `bytes` literals, handling of `Ellipsis` constant, and whether metadata fields (`lineno`, `col_offset`, etc.) are included. The converter should be resilient to missing metadata fields and should not depend on any specific serializer's conventions for unserializable types.

---

## §7. Python AST Node Categories

### 7.1 Supported Node Summary

#### Literals and Names (~5 nodes)
`Constant`, `Name`, `List`, `Tuple`, `Dict`

#### Operators (~29 nodes)

**Binary (13):** `Add`, `Sub`, `Mult`, `Div`, `FloorDiv`, `Mod`, `Pow`, `LShift`, `RShift`, `BitOr`, `BitXor`, `BitAnd`, `MatMult`

**Unary (4):** `UAdd`, `USub`, `Not`, `Invert`

**Boolean (2):** `And`, `Or`

**Comparison (10):** `Eq`, `NotEq`, `Lt`, `LtE`, `Gt`, `GtE`, `Is`, `IsNot`, `In`, `NotIn`

Note: `MatMult`, `LShift`, `RShift`, `BitOr`, `BitXor`, `BitAnd`, and `Invert` are listed for completeness but may raise `UnsupportedNodeError` initially. Most algorithmic code does not use matrix multiplication or bitwise shifts (though `BitAnd`, `BitOr`, `BitXor` do appear in some problems).

**IMPORTANT — Bitwise operators require `import Bitwise`:** The operators `<<<`, `>>>`, `|||`, `&&&`, `^^^`, and `~~~` are only available after `use Bitwise` or `import Bitwise`. The code generator must detect when any bitwise operator is used and emit `import Bitwise` at the top of the generated code. Without this, generated code using bitwise operators will fail to compile. Detection: set `context.uses_bitwise = true` when any bitwise operator node is encountered; at `Module` level, if the flag is true, prepend `import Bitwise` to the output.

#### Expressions (~12 nodes)
`BinOp`, `UnaryOp`, `Compare`, `BoolOp`, `Call`, `IfExp`, `Subscript`, `Attribute`, `ListComp`, `Lambda`, `Slice`, `Starred` (in function call arguments only — `*args` unpacking)

#### Statements (~12 nodes)
`Assign`, `AugAssign`, `Return`, `If`, `For`, `While`, `Pass`, `Break`, `Continue`, `Assert`, `Expr` (statement wrapper), `FunctionDef`

#### Auxiliary (~8 nodes)
`arguments`, `arg`, `keyword`, `comprehension`, `Module`, `Load`, `Store`, `Del`

**Total: ~66 node types**, of which ~29 are trivial operator nodes and ~3 are context markers (`Load`/`Store`/`Del`) that the converter ignores.

### 7.2 Explicitly Unsupported (raises `UnsupportedNodeError`)

`ClassDef`, `AsyncFunctionDef`, `AsyncFor`, `AsyncWith`, `Import`, `ImportFrom`, `Try`, `TryStar`, `ExceptHandler`, `With`, `Raise`, `Global`, `Nonlocal`, `Yield`, `YieldFrom`, `Await`, `Match`, `Delete`, `AnnAssign`, `TypeAlias`, `GeneratorExp`, `SetComp`, `DictComp`, `FormattedValue`, `JoinedStr`, `TemplateStr`, `Interpolation`, `Set`, `NamedExpr`, `Starred` (in assignment target unpacking — `a, *b = ...`)

**`GeneratorExp` interaction with builtins:** Note that `GeneratorExp` is common inside calls to mapped builtins: `sum(x**2 for x in items)`, `max(abs(x) for x in items)`, `min(len(s) for s in strings)`. These will crash on the `GeneratorExp` child node even though `sum`/`max`/`min` are in the builtins table. An implementer encountering this pattern should either (a) special-case `Call` nodes where the argument is a `GeneratorExp` and the function is a known builtin (converting to `Enum.sum(Enum.map(items, fn x -> x ** 2 end))` or a `for` comprehension), or (b) raise `UnsupportedNodeError` with a clear message like "GeneratorExp inside sum() — consider rewriting as a list comprehension."

---

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

**CRITICAL: Use `&&`/`||`/`!`, NOT `and`/`or`/`not`.** Elixir's `and`/`or`/`not` are strict boolean operators that raise `BadBooleanError` on non-boolean values (like `0`, `""`, `[]`). Python's `and`/`or`/`not` accept any value. Since `&&`/`||`/`!` accept any truthy/falsy value in Elixir, they're the correct mapping.

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
|-----|--------------------------|
| `{:+, [], [1, 2]}` | `"1 + 2"` |
| `{:&&, [], [{:a, [], nil}, {:b, [], nil}]}` | `"a && b"` |
| `{:==, [], [{:x, [], nil}, nil]}` | `"x == nil"` |
| `{:fn, [], [{:->, [], [[{:x, [], nil}], {:+, [], [{:x, [], nil}, 1]}]}]}` | `"fn x -> x + 1 end"` |
| `{:if, [], [{:cond, [], nil}, [do: {:a, [], nil}, else: {:b, [], nil}]]]}` | `"if cond, do: a, else: b"` |
| `{:__block__, [], [{:=, [], [{:x, [], nil}, 1]}, {:x, [], nil}]}` | `"x = 1\nx"` |
| `{{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [{:list, [], nil}]}` | `"Enum.sort(list)"` |

**Important gotcha:** `Code.format_string!/1` returns **iodata**, NOT a binary string. To get a binary string, pipe through `IO.iodata_to_binary/1`. Note that `Macro.to_string/1` does return a binary string directly — the iodata gotcha applies only to `Code.format_string!/1`.
