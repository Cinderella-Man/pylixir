## Appendix A: Python AST JSON Examples

### A.1 Simple Assignment

**Python:** `x = 42`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "Assign",
      "targets": [{"_type": "Name", "id": "x", "ctx": {"_type": "Store"}}],
      "value": {"_type": "Constant", "value": 42}
    }
  ]
}
```

### A.2 If-Elif-Else

**Python:** `if a: x = 1\nelif b: x = 2\nelse: x = 3`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "If",
      "test": {"_type": "Name", "id": "a", "ctx": {"_type": "Load"}},
      "body": [
        {
          "_type": "Assign",
          "targets": [{"_type": "Name", "id": "x", "ctx": {"_type": "Store"}}],
          "value": {"_type": "Constant", "value": 1}
        }
      ],
      "orelse": [
        {
          "_type": "If",
          "test": {"_type": "Name", "id": "b", "ctx": {"_type": "Load"}},
          "body": [
            {
              "_type": "Assign",
              "targets": [{"_type": "Name", "id": "x", "ctx": {"_type": "Store"}}],
              "value": {"_type": "Constant", "value": 2}
            }
          ],
          "orelse": [
            {
              "_type": "Assign",
              "targets": [{"_type": "Name", "id": "x", "ctx": {"_type": "Store"}}],
              "value": {"_type": "Constant", "value": 3}
            }
          ]
        }
      ]
    }
  ]
}
```

### A.3 While Loop with Break

**Python:** `while True:\n    if x > 10: break\n    x += 1`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "While",
      "test": {"_type": "Constant", "value": true},
      "body": [
        {
          "_type": "If",
          "test": {
            "_type": "Compare",
            "left": {"_type": "Name", "id": "x", "ctx": {"_type": "Load"}},
            "ops": [{"_type": "Gt"}],
            "comparators": [{"_type": "Constant", "value": 10}]
          },
          "body": [{"_type": "Break"}],
          "orelse": []
        },
        {
          "_type": "AugAssign",
          "target": {"_type": "Name", "id": "x", "ctx": {"_type": "Store"}},
          "op": {"_type": "Add"},
          "value": {"_type": "Constant", "value": 1}
        }
      ],
      "orelse": []
    }
  ]
}
```

### A.4 List Comprehension

**Python:** `[x * 2 for x in items if x > 0]`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "Expr",
      "value": {
        "_type": "ListComp",
        "elt": {
          "_type": "BinOp",
          "left": {"_type": "Name", "id": "x", "ctx": {"_type": "Load"}},
          "op": {"_type": "Mult"},
          "right": {"_type": "Constant", "value": 2}
        },
        "generators": [
          {
            "_type": "comprehension",
            "target": {"_type": "Name", "id": "x", "ctx": {"_type": "Store"}},
            "iter": {"_type": "Name", "id": "items", "ctx": {"_type": "Load"}},
            "ifs": [
              {
                "_type": "Compare",
                "left": {"_type": "Name", "id": "x", "ctx": {"_type": "Load"}},
                "ops": [{"_type": "Gt"}],
                "comparators": [{"_type": "Constant", "value": 0}]
              }
            ],
            "is_async": 0
          }
        ]
      }
    }
  ]
}
```

### A.5 Function with Default Arguments

**Python:** `def greet(name, greeting="Hello"): return greeting + ", " + name + "!"`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "FunctionDef",
      "name": "greet",
      "args": {
        "_type": "arguments",
        "posonlyargs": [],
        "args": [
          {"_type": "arg", "arg": "name", "annotation": null},
          {"_type": "arg", "arg": "greeting", "annotation": null}
        ],
        "kwonlyargs": [],
        "kw_defaults": [],
        "defaults": [
          {"_type": "Constant", "value": "Hello"}
        ]
      },
      "body": [
        {
          "_type": "Return",
          "value": {
            "_type": "BinOp",
            "left": {
              "_type": "BinOp",
              "left": {
                "_type": "BinOp",
                "left": {"_type": "Name", "id": "greeting", "ctx": {"_type": "Load"}},
                "op": {"_type": "Add"},
                "right": {"_type": "Constant", "value": ", "}
              },
              "op": {"_type": "Add"},
              "right": {"_type": "Name", "id": "name", "ctx": {"_type": "Load"}}
            },
            "op": {"_type": "Add"},
            "right": {"_type": "Constant", "value": "!"}
          }
        }
      ],
      "decorator_list": [],
      "returns": null,
      "type_comment": null
    }
  ]
}
```

### A.6 Slicing

**Python:** `items[1:3]`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "Expr",
      "value": {
        "_type": "Subscript",
        "value": {"_type": "Name", "id": "items", "ctx": {"_type": "Load"}},
        "slice": {
          "_type": "Slice",
          "lower": {"_type": "Constant", "value": 1},
          "upper": {"_type": "Constant", "value": 3},
          "step": null
        },
        "ctx": {"_type": "Load"}
      }
    }
  ]
}
```

### A.7 Dictionary Iteration

**Python:** `for k, v in my_dict.items(): print(k, v)`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "For",
      "target": {
        "_type": "Tuple",
        "elts": [
          {"_type": "Name", "id": "k", "ctx": {"_type": "Store"}},
          {"_type": "Name", "id": "v", "ctx": {"_type": "Store"}}
        ],
        "ctx": {"_type": "Store"}
      },
      "iter": {
        "_type": "Call",
        "func": {
          "_type": "Attribute",
          "value": {"_type": "Name", "id": "my_dict", "ctx": {"_type": "Load"}},
          "attr": "items",
          "ctx": {"_type": "Load"}
        },
        "args": [],
        "keywords": []
      },
      "body": [
        {
          "_type": "Expr",
          "value": {
            "_type": "Call",
            "func": {"_type": "Name", "id": "print", "ctx": {"_type": "Load"}},
            "args": [
              {"_type": "Name", "id": "k", "ctx": {"_type": "Load"}},
              {"_type": "Name", "id": "v", "ctx": {"_type": "Load"}}
            ],
            "keywords": []
          }
        }
      ],
      "orelse": []
    }
  ]
}
```

### A.8 String Repetition

**Python:** `s = "abc" * 3`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "Assign",
      "targets": [{"_type": "Name", "id": "s", "ctx": {"_type": "Store"}}],
      "value": {
        "_type": "BinOp",
        "left": {"_type": "Constant", "value": "abc"},
        "op": {"_type": "Mult"},
        "right": {"_type": "Constant", "value": 3}
      }
    }
  ]
}
```

### A.9 List Repetition (Array Initialization)

**Python:** `dp = [0] * n`

**AST JSON:**
```json
{
  "_type": "Module",
  "body": [
    {
      "_type": "Assign",
      "targets": [{"_type": "Name", "id": "dp", "ctx": {"_type": "Store"}}],
      "value": {
        "_type": "BinOp",
        "left": {
          "_type": "List",
          "elts": [{"_type": "Constant", "value": 0}],
          "ctx": {"_type": "Load"}
        },
        "op": {"_type": "Mult"},
        "right": {"_type": "Name", "id": "n", "ctx": {"_type": "Load"}}
      }
    }
  ]
}
```

---

## Appendix B: Edge Case Quick Reference Card

A compact reference for the most common correctness traps.

| # | Trap | Wrong | Right | Section |
|---|------|-------|-------|---------|
| 1 | Floor division | `div(a, b)` | `Integer.floor_div(a, b)` | §11.1 |
| 2 | Modulo | `rem(a, b)` | `Integer.mod(a, b)` | §11.2 |
| 3 | Truthiness | `if my_list do` | `if truthy?(my_list) do` | §11.3 |
| 4 | Chained comparison | `a < b < c` | `a < b && b < c` | §11.4 |
| 5 | Boolean operators | `a and b` | `a && b` | §9.7 |
| 6 | `enumerate` order | `{i, x}` | `{x, i}` (destructure swapped) | §11.7 |
| 7 | `strip(chars)` | `String.trim(s, chars)` | Regex-based helper | §11.12 |
| 8 | `replace(s, o, n, 1)` | `String.replace(s, o, n)` | `String.replace(s, o, n, global: false)` | §11.13 |
| 9 | `return` in loop | Direct return | `try`/`throw`/`catch` | §13.14 |
| 10 | `continue` in while | Skip | Recursive call to helper | §13.8 |
| 11 | `break` in while | No-op | `throw({:break, {state}})` | §13.8 |
| 12 | `print(a, b)` | `IO.puts(a, b)` | `IO.puts(Enum.join(..., " "))` | §11.18 |
| 13 | `len(s)` for strings | `length(s)` | `py_len(s)` (runtime helper) | §9.10 |
| 14 | `in` for dicts/strings | `x in collection` | `py_in(x, collection)` | §9.9 |
| 15 | `not in` | `not x in items` | `!py_in(x, items)` | §9.9 |
| 16 | Closure capture | `fn -> x end` (captures value) | Document as known limitation | §11.6 |
| 17 | `d[key]` missing | `Map.get(d, key)` | `Map.fetch!(d, key)` | §11.11 |
| 18 | `Code.format_string!` | Returns string | Returns iodata; use `IO.iodata_to_binary/1` | §6.1.1 |
| 19 | String concat with `+` | `"a" + "b"` | `py_add("a", "b")` or `"a" <> "b"` | §11.19 |
| 20 | String/list repetition `*` | `"abc" * 3` raises error | `py_mult("abc", 3)` dispatches correctly | §11.20 |
| 21 | Slicing `x[1:3]` | No Elixir equivalent | `Enum.slice(x, 1..2)` | §11.21 |
| 22 | `range` negative step | `a..(b-1)//s` | `a..(b+1)//s` when `s < 0` | §11.22 |
| 23 | Power with floats | `Integer.pow(a, b)` | `:math.pow(a, b)` | §11.23 |
| 24 | Boolean arithmetic | `true + 1` raises error | `py_bool_to_int(true) + 1` | §11.24 |
| 25 | `not`/`!` truthiness | `!0` → `false` | `!truthy?(0)` → `true` | §11.3 |
| 26 | `is` operator | `===` | `==` | §13.11 |
| 27 | For-loop mutation | `Enum.each` (loses state) | `Enum.reduce` with accumulator | §13.4 |
| 28 | Multiple assignment | `a = 5; b = 5` (for calls) | `temp = expr; a = temp; b = temp` | §6.3.7 |
| 29 | `min`/`max` single arg | `min(list)` | `Enum.min(list)` | §12.8 |
| 30 | `int(x, base)` | `trunc(x)` | `String.to_integer(x, base)` | §12.8 |
| 31 | `dict.items()` | Not handled | `Map.to_list(d)` | §9.5 |
| 32 | `continue` in for | No equivalent | Return accumulator unchanged | §13.4 |
| 33 | Nested for mutation | Inner scope lost | Nested `Enum.reduce` | §13.4 |
| 34 | `sorted` with reverse | `Enum.sort_by(x, f)` (no order) | `Enum.sort_by(x, f, :desc)` | §12.8 |
| 35 | `int()` no args | `trunc(nil)` crashes | `0` | §12.8 |
| 36 | `hex()` casing | `Integer.to_string(n, 16)` → `"FF"` | `String.downcase(...)` → `"ff"` | §11.15 |
| 37 | `math.inf` | `:infinity` (no numeric ops) | Raise `UnsupportedNodeError` | §11.17 |
| 38 | `print()` no args | Not handled | `IO.puts("")` | §11.18 |
| 39 | `pop()` no args | Not handled | `List.delete_at(list, -1)` | §9.6 |
| 40 | `MatMult` operator | Silent wrong code | Raise `UnsupportedNodeError` | §7.1 |
| 41 | While loop state lost | Helper returns `nil` | Helper returns `{state}` tuple | §13.8 |
| 42 | Tuple swap order | `a = b; b = a` | `{a, b} = {b, a}` | §13.19 |
| 43 | `truthy?` empty map | `map == %{}` | `map_size(map) == 0` | §11.3 |
| 44 | `truthy?` empty MapSet | `map_size(MapSet.new()) == 0` (returns 2!) | `MapSet.size(s) > 0` | §11.3 |
| 45 | String char access | `Enum.at(s, i)` | `py_getitem(s, i)` dispatches to `String.at` | §12.5 |
| 46 | `float()` no args | Not handled | `0.0` | §12.8 |
| 47 | List concat with `+` | `[1,2] + [3,4]` raises error | `py_add([1,2], [3,4])` → `a ++ b` | §11.19 |
| 48 | Float floor div/mod | `Integer.floor_div` on floats crashes | Document as known limitation | §11.1 |
| 49 | `^^^` deprecation | `a ^^^ b` emits warning (Elixir 1.12+) | Use `Bitwise.bxor(a, b)` or accept warnings | §7.1 |
| 50 | `print(True)` casing | `to_string(true)` → `"true"` | `py_str(true)` → `"True"` | §11.18 |
| 51 | `print(None)` output | `to_string(nil)` → `""` | `py_str(nil)` → `"None"` | §11.18 |
| 52 | `int(True)` / `int(False)` | `py_int(true)` crashes | Add boolean clauses to `py_int` | §13.20 |
| 53 | `int("  42  ")` whitespace | `String.to_integer("  42  ")` crashes | `String.trim(x) \|> String.to_integer()` | §13.20 |
| 54 | `float("3")` format | `String.to_float("3")` crashes | Use `Float.parse/1` | §13.20 |
| 55 | Tuple negative index | `elem(t, -1)` crashes | `elem(t, tuple_size(t) + key)` | §13.20 |
| 56 | `py_mult` with booleans | `true * 3` crashes | Add `is_boolean` clauses to `py_mult` | §11.20 |
| 57 | `d[key] += 1` default | `Map.get(d, key, 0)` silent wrong | `Map.fetch!(d, key)` to match Python `KeyError` | §9.3 |
| 58 | `if`/`cond` truthiness | `cond do my_list -> ...` | `cond do truthy?(my_list) -> ...` | §13.12 |

---

*End of RFC-001 v9*
