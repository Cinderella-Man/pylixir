# Regression: Python's `.index(x)` exists on str, list, and tuple, with
# the same name but different semantics. Pylixir's dispatch unconditionally
# emitted `py_str_index`, whose `py_str_find` → `String.split(...)` path
# crashes with `FunctionClauseError in String.split/3` for non-binary
# receivers. Adapted from a real eval-corpus failure (seed_12947,
# `sums.index(max_val)` over `sums = [chest, biceps, back]`).

# str.index — substring search (existing behaviour).
print("hello world".index("world"))

# list.index — equality match.
sums = [10, 20, 30]
print(sums.index(20))
print(sums.index(10))
print(sums.index(30))

# Idiom from the failing eval sample: pick the label of the max element.
chest, biceps, back = 7, 11, 5
muscles = [chest, biceps, back]
max_val = max(muscles)
index = muscles.index(max_val)
print(["chest", "biceps", "back"][index])

# tuple.index — same semantics as list.index.
t = (5, 6, 7)
print(t.index(7))
