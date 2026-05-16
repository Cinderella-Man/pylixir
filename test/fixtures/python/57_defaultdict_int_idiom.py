# Regression: `from collections import defaultdict` was rejected. Fix:
# the import is now allowed; `defaultdict(int)` emits a plain `%{}`;
# `py_getitem` for maps returns `nil` for missing keys (not raise);
# `py_add(nil, x)` and `py_add(x, nil)` treat `nil` as the additive
# identity. Net result: `d[k] += 1` on a missing key works
# (`nil + 1 = 1`), matching Python's defaultdict(int) idiom. Adapted
# from an eval-corpus failure (unsupported--ImportFrom, 2026-05-16).
#
# Trade-off documented in `py_getitem`'s comment: legitimate
# missing-key bugs against plain dicts surface as `nil` propagation
# instead of an immediate `KeyError`. Python users get `dict.get(k,
# default)` for the explicit version, which routes to `Map.get` and
# is unaffected.
from collections import defaultdict

# The canonical defaultdict(int) histogram idiom.
counts = defaultdict(int)
for x in ["a", "b", "a", "c", "b", "a"]:
    counts[x] += 1

# Sorted iteration so output is deterministic regardless of map order.
for k in sorted(counts.keys()):
    print(k, counts[k])

# .get with explicit default still works.
print(counts.get("z", 0))
print(counts.get("a"))
