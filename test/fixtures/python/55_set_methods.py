# Regression: Python's `set.union`/`intersection`/etc. raised "method
# `.union()` is not supported". Fix: `Pylixir.Nodes.AttributeMethods`
# adds clauses routing the standard set methods to their `MapSet.*`
# equivalents. Adapted from an eval-corpus failure
# (unsupported--Call, 2026-05-16). (The original eval snippet used
# the method on a user-class instance and won't compile cleanly —
# class support is a separate concern — but this fix enables every
# *legitimate* set use.)
a = set([1, 2, 3, 4])
b = set([3, 4, 5, 6])

print(sorted(a.union(b)))
print(sorted(a.intersection(b)))
print(sorted(a.difference(b)))
print(sorted(a.symmetric_difference(b)))
print(a.issubset(set([1, 2, 3, 4, 5])))
print(a.issuperset(set([1, 2])))
print(a.isdisjoint(set([10, 11])))
