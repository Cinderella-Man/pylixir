# Regression: `itertools.product(*iters)` and the `from itertools
# import product` binding were unsupported, blocking 2 eval samples
# that use it as a nested-for-loop alternative. Added a clause
# routing to `py_product/2` (Cartesian product over a list-of-iters,
# yielding tuples to match Python's tuple-shaped elements).

import itertools

# Two iters.
for combo in itertools.product([1, 2], ["a", "b"]):
    print(combo)

# Three iters.
for combo in itertools.product([0, 1], [0, 1], [0, 1]):
    print(combo)

# Empty product — single empty tuple, matching Python.
for combo in itertools.product():
    print(combo)

# repeat=N.
for combo in itertools.product([0, 1], repeat=3):
    print(combo)

# From-import path.
from itertools import product
for combo in product(["x", "y"], [1, 2]):
    print(combo)

# Unpack in for-target — the common idiom from eval samples.
total = 0
for a, b in itertools.product([1, 2, 3], [10, 20]):
    total += a * b
print(total)
