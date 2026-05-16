# Regression: `.copy()` raised `UnsupportedNodeError("Call")` because
# the method wasn't in the dispatch table. Fix: `Pylixir.Nodes.AttributeMethods`
# treats `.copy()` as an identity — Elixir's containers are immutable
# so the copy *is* the value, and the existing mutation rewrites
# (`xs.remove(y)` → `xs = List.delete(xs, y)`) already preserve the
# original. Adapted from an eval-corpus failure (unsupported--Call,
# 2026-05-16).

# List: subsequent mutation on the copy must not affect the original.
xs = [1, 2, 3, 4]
ys = xs.copy()
ys.remove(2)
print(xs)
print(ys)

# Dict: same invariant.
d = {"a": 1, "b": 2}
e = d.copy()
e["a"] = 99
print(d["a"])
print(e["a"])
