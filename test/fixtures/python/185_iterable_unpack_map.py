# Regression: Python's `a, b, c = <iterable>` unpacks ANY iterable —
# list, tuple, generator. Pylixir used to emit `{a, b, c} = rhs` even
# when the RHS was a list (e.g. the result of `map(...)` or `split()`),
# which raises `MatchError` at runtime. Now the converter emits
# `[a, b, c] = py_iter_to_list(rhs)` when the RHS isn't statically a
# tuple. Adapted from an eval-corpus failure (seed_12944, 2026-05-20).

# `map(int, ...)` returns a list in the lowered Elixir — list pattern.
data = "1 2 3"
n, m, k = map(int, data.split())
print(n + m + k)

# `str.split()` also returns a list — same path, no `int` cast.
a, b = "foo bar".split()
print(a + "/" + b)

# List literal — static list, list pattern, no coerce needed.
x, y, z = [10, 20, 30]
print(x - y + z)

# Tuple literal — static tuple, tuple pattern preserved.
p, q = (7, 9)
print(p * q)

# Nested target with list RHS — outer pattern stays tuple-shaped (no
# nested list-pattern transform yet); the inner Tuple binds positionally.
count, (lo, hi) = (3, (1, 9))
print(f"{count}:{lo}-{hi}")
