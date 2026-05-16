# Regression: `float('inf')` raised "RFC §6.19 — Elixir has no
# inf/nan" — but the idiomatic Python use is as a sentinel in min/max
# loops. Fix: emit a large-magnitude float (1.0e308 / -1.0e308) for
# `inf` / `-inf`. Observationally identical for sentinel comparisons
# against any practical finite value. NaN stays rejected (no good
# Elixir representation). Adapted from an eval-corpus failure
# (unsupported--Call, 2026-05-16).

# Negative infinity as a max-finding sentinel.
max_total = -float('inf')
for x in [3, 1, 4, 1, 5, 9, 2, 6]:
    if x > max_total:
        max_total = x
print(max_total)

# Positive infinity as a min-finding sentinel.
min_total = float('inf')
for x in [3, 1, 4, 1, 5, 9, 2, 6]:
    if x < min_total:
        min_total = x
print(min_total)

# The string variants Python normalises identically.
print(float('+inf') > 1e9)
print(float('Infinity') > 1e9)
print(float('-Infinity') < -1e9)
