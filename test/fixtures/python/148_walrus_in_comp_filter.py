# Regression: `[y for x in xs if (y := f(x)) > 0]` raised
# "undefined variable y" at compile time. The comp lowering used
# `Enum.filter + Enum.map` — two separate fns, so the walrus binding
# in the filter fn wasn't in scope when the map fn read `y`. Fix:
# when the comp has any `if` clauses, lower to `Enum.flat_map(iter,
# fn x -> if filter, do: [elt], else: [] end)` — the filter and elt
# share one fn so walrus bindings flow through.

# Walrus in filter, read in elt — the trigger case.
print([y for x in range(5) if (y := x * 2) > 4])
# Python: [6, 8]

# Walrus in filter, multi-condition `if a if b`.
print([y for x in range(10) if (y := x * x) > 5 if y < 50])
# Python: [9, 16, 25, 36, 49]

# Walrus in elt (no filter) — already worked.
print([(y := x + 1) for x in range(3)])
# Python: [1, 2, 3]

# Walrus persists into the elt expression (filter binds, elt reads).
print([(x, y) for x in range(3) if (y := x * 10) >= 0])
# Python: [(0, 0), (1, 10), (2, 20)]

# Same shape inside a set comp.
print(sorted({y for x in range(5) if (y := x % 3) > 0}))
# Python: [1, 2]
