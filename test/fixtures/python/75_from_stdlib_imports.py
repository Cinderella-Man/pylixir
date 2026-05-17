# Regression: `from sys import stdin`, `from bisect import bisect_left`,
# `from heapq import heappush, heappop`, `from itertools import combinations`,
# `from math import factorial` / `comb` all raised "is not supported".
# Fix: a generic `stdlib_from_import_alias/5` binds each imported name
# to a value (sys.argv, sys.maxsize) or a `&local_helper/arity`
# capture (bisect/heapq/itertools functions). `stdin` is bound to a
# sentinel; `.read()`/`.readline()` on it dispatch through
# attribute_methods. Adapted from eval-corpus failures
# (unsupported--ImportFrom, 2026-05-16).
from math import factorial, comb, sqrt
from bisect import bisect_left, bisect_right
from itertools import combinations

# math
print(factorial(5))                       # 120
print(comb(6, 2))                         # 15
print(int(sqrt(49)))                      # 7

# bisect — bound as 2-arg lambdas.
xs = [1, 3, 5, 7, 9]
print(bisect_left(xs, 4))                 # 2
print(bisect_right(xs, 5))                # 3

# itertools.combinations — returns list-like; iterate and index so the
# golden assertion doesn't depend on tuple-vs-list print format
# (Pylixir's combinations helper returns lists, like py_permutations).
for combo in combinations([1, 2, 3, 4], 2):
    print(combo[0], combo[1])
