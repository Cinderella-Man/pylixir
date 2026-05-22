# Regression: `defaultdict(set)` with `d[key].add(x)` on a missing
# key. The auto-vivification read returns nil, and `.add` lowered to
# `MapSet.put(nil, x)` crashed (FunctionClauseError). Mirror the
# nil-tolerant `py_append(nil, v)` path used for `defaultdict(list)`.
# Adapted from an eval-corpus FunctionClauseError (seed_25097). Output
# uses len/sorted to stay independent of set iteration order.
from collections import defaultdict

lines = defaultdict(set)
lines[(1, 0, 0)].add((2, 3))
lines[(1, 0, 0)].add((4, 5))
lines[(1, 0, 0)].add((2, 3))  # duplicate, no effect
lines[(0, 1, 0)].add((9, 9))
print(len(lines[(1, 0, 0)]))  # 2
print(len(lines[(0, 1, 0)]))  # 1

# Iterating keys and counting members, like the corpus shape.
best = 0
for key in lines:
    best = max(best, len(lines[key]))
print(best)  # 2

# Plain (non-defaultdict) set .add still works.
seen = set()
seen.add(7)
seen.add(7)
seen.add(8)
print(len(seen))  # 2
print(sorted(seen))  # [7, 8]

# defaultdict(set) membership check after adds.
print((2, 3) in lines[(1, 0, 0)])  # True
print((0, 0) in lines[(1, 0, 0)])  # False
