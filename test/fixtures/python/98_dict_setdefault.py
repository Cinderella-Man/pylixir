# Regression: `d.setdefault(k, default)` raised "method `.setdefault()`
# is not supported". Fix: added to `Mutations.@methods` and a new
# `mutation_rhs("setdefault", …)` clause emitting `Map.put_new(d, k, v)`.
# Also added to the `@mutation_methods` lists in ModuleAnalysis +
# LoopAnalysis so loop accumulators and module-attr promotion both
# see d as mutated.

# Statement-context (most common): set k=default if k not in d.
d = {"a": 1}
d.setdefault("a", 99)        # no-op: "a" already present
d.setdefault("b", 2)         # sets b=2
print(sorted(d.items()))     # [("a", 1), ("b", 2)]

# Inside a loop — accumulating groups.
groups = {}
for k, v in [("x", 1), ("y", 2), ("x", 3), ("y", 4), ("z", 5)]:
    groups.setdefault(k, 0)
    groups[k] += v
print(sorted(groups.items())) # [("x", 4), ("y", 6), ("z", 5)]
