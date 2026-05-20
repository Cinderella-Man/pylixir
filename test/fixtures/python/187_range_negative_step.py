# Regression: `range(start, stop, -1)` was emitting
# `start..(stop-1)//-1`, which walks past 0 (Elixir ranges are
# inclusive on both ends; for a negative step the Elixir stop must be
# `stop_python + 1`). The off-by-2 produced negative indices in
# downstream `xs[i]` reads, eventually crashing as `ArithmeticError`
# when the wrapped value was multiplied. Adapted from seed_16752
# (`for i in range(n-1, -1, -1): ...`).

# Trivial form.
print(list(range(5, -1, -1)))   # [5, 4, 3, 2, 1, 0]

# n=1 — the boundary that broke the eval sample.
n = 1
print(list(range(n - 1, -1, -1)))   # [0]

# n=4 — multi-element countdown.
n = 4
print(list(range(n - 1, -1, -1)))   # [3, 2, 1, 0]

# Negative step with non-zero stop.
print(list(range(10, 0, -2)))   # [10, 8, 6, 4, 2]

# Positive step still excludes stop.
print(list(range(1, 10, 2)))   # [1, 3, 5, 7, 9]

# Empty range when start <= stop with negative step.
print(list(range(0, 5, -1)))   # []

# Empty range when start >= stop with positive step.
print(list(range(5, 0, 1)))   # []
