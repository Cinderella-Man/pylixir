# Regression: `math.prod`, `math.lcm`, and `math.dist` returned
# `:no_clause` from `Pylixir.Stdlib.Math.call/4` and bubbled up as
# UnsupportedNodeError. Added explicit clauses lowering to new runtime
# helpers `py_math_prod/2`, `py_math_lcm/1`, `py_math_dist/2` in
# `Pylixir.RuntimeHelpers.MathExt`.

import math

# prod — int product, float product, empty (returns start=1).
print(math.prod([1, 2, 3, 4]))         # 24
print(math.prod([2.5, 4]))             # 10.0
print(math.prod([]))                   # 1
print(math.prod([1, 2, 3, 1]))         # 6

# lcm — variadic; identity element is 1.
print(math.lcm(4, 6))                  # 12
print(math.lcm(12, 18, 24))            # 72
print(math.lcm(7))                     # 7
print(math.lcm())                      # 1
print(math.lcm(0, 5))                  # 0

# dist — Euclidean distance between two coord tuples/lists.
print(math.dist([0, 0], [3, 4]))       # 5.0
print(math.dist([1, 2, 3], [4, 6, 3])) # 5.0
print(math.dist((0,), (5,)))           # 5.0
