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

---

## Appendix B: Edge Case Quick Reference Card

A compact reference for the most common correctness traps.

| # | Trap | Wrong | Right | Section |
|---|------|-------|-------|---------|
| 1 | Floor division | `div(a, b)` | `Integer.floor_div(a, b)` | §11.1 |
| 2 | Modulo | `rem(a, b)` | `Integer.mod(a, b)` | §11.2 |
| 3 | Truthiness | `if my_list do` | `if my_list != [] do` | §11.3 |
| 4 | Chained comparison | `a < b < c` | `a < b && b < c` | §11.4 |
| 5 | Boolean operators | `a and b` | `a && b` | §9.7 |
| 6 | `enumerate` order | `{i, x}` | `{x, i}` then swap | §11.7 |
| 7 | `strip(chars)` | `String.trim(s, chars)` | Regex-based helper | §11.12 |
| 8 | `replace(s, o, n, 1)` | `String.replace(s, o, n)` | `String.replace(s, o, n, global: false)` | §11.13 |
| 9 | `return` in loop | Direct return | `try`/`throw`/`catch` | §13.13 |
| 10 | `continue` in while | Skip | Recursive call to helper | §13.7 |
| 11 | `break` in while | No-op | `throw(:break)` | §13.7 |
| 12 | `print(a, b)` | `IO.puts(a, b)` | `IO.puts(Enum.join(..., " "))` | §11.18 |
| 13 | `len(s)` for strings | `length(s)` | `String.length(s)` | §9.10 |
| 14 | `in` for sets | `x in set` | `MapSet.member?(set, x)` | §9.9 |
| 15 | `not in` | `not x in items` | `!(x in items)` | §9.9 |
| 16 | Closure capture | `fn -> x end` (captures value) | Document as known limitation | §11.6 |
| 17 | `d[key]` missing | `d[key]` | `Map.fetch!(d, key)` | §11.11 |
| 18 | `Code.format_string!` | Returns string | Returns iodata; use `IO.iodata_to_binary/1` | §6.1.1 |
| 19 | String concat with `+` | `"a" + "b"` | `"a" <> "b"` | §11.19 |
| 20 | Slicing `x[1:3]` | No Elixir equivalent | `Enum.slice(x, 1..2)` | §11.20 |
| 21 | `range` negative step | `a..(b-1)//s` | `a..(b+1)//s` when `s < 0` | §11.21 |
| 22 | Power with floats | `Integer.pow(a, b)` | `:math.pow(a, b)` | §11.22 |
| 23 | `not`/`!` truthiness | `!0` → `false` | `!truthy?(0)` → `true` | §11.3 |
| 24 | `is` operator | `:===` | `:==` | §13.10 |
| 25 | For-loop mutation | `Enum.each` (loses state) | `Enum.reduce` with accumulator | §13.4 |
| 26 | Multiple assignment | `a = 5; b = 5` (for calls) | `temp = expr; a = temp; b = temp` | §6.3.7 |
| 27 | `min`/`max` single arg | `min(list)` | `Enum.min(list)` | §12.8 |
| 28 | `int(x, base)` | `trunc(x)` | `String.to_integer(x, base)` | §12.8 |
| 29 | `dict.items()` | Not handled | `Map.to_list(d)` | §9.5 |

---

*End of RFC-001 v6*
