# Regression: `enumerate(xs, N)` with a positional start arg raised
# "enumerate/2 is not a supported call shape" — only the `start=N`
# kwarg form had a clause. Added `enumerate(xs, start)` positional
# clause sharing the same emit helper.

xs = ["a", "b", "c"]

# Default — start at 0.
for i, x in enumerate(xs):
    print(i, x)

# Positional start.
for i, x in enumerate(xs, 1):
    print(i, x)

# kwarg start (was already supported).
for i, x in enumerate(xs, start=10):
    print(i, x)

# Positional start with negative.
for i, x in enumerate(["x", "y"], -1):
    print(i, x)
