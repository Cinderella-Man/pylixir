# Regression: `del coll[k]` raised `UnsupportedNodeError("Delete")` —
# no Delete-node clause existed. Fix: lower to
# `coll = py_delitem(coll, k)` via a new runtime helper that's
# polymorphic across list / map / MapSet. `ModuleAnalysis` and
# `LoopAnalysis` also recognise it as a mutation of the root so
# top-level dicts that get `del`-from aren't promoted to module
# attrs and for-loop bodies thread the root correctly.
# Adapted from an eval-corpus failure (unsupported--Delete, 2026-05-16).

# del on a dict key.
d = {"a": 1, "b": 2, "c": 3}
del d["b"]
print(sorted(d.keys()))

# del on a list index.
xs = [10, 20, 30, 40]
del xs[1]
print(xs)

# del inside a for-loop body — root mutation must thread through.
nums = {0: "z", 1: "o", 2: "t", 3: "h"}
for key in [0, 2]:
    del nums[key]

print(sorted(nums.keys()))
