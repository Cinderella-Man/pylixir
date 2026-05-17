# Regression: `itertools.combinations_with_replacement(iter, r)` and
# the matching `from itertools import combinations_with_replacement`
# were unsupported. Added clauses routing to a new runtime helper
# `py_combinations_with_replacement/2`. Differs from `combinations`
# in the recursion: after picking element `h`, the next pick may
# pick `h` again (so we recurse over `[h | t]`, not `t`).
#
# Outputs use len/join (same as fixture 56) to bypass the
# tuple-vs-list shape difference between CPython and Pylixir.

from itertools import combinations_with_replacement
import itertools

# Counts (shape-independent).
print(len(list(combinations_with_replacement([1, 2, 3], 2))))     # 6
print(len(list(combinations_with_replacement("ab", 3))))           # 4
print(len(list(combinations_with_replacement([1, 2], 4))))         # 5
print(len(list(combinations_with_replacement([], 2))))             # 0
print(len(list(combinations_with_replacement([1, 2], 0))))         # 1 (empty combo)

# Element-wise probe — join inner items to a string per combo.
print(",".join(["".join(map(str, c)) for c in combinations_with_replacement([1, 2, 3], 2)]))
# Python: 11,12,13,22,23,33

print(",".join(["".join(c) for c in combinations_with_replacement("ab", 3)]))
# Python: aaa,aab,abb,bbb

# Module-form access — should match.
print(len(list(itertools.combinations_with_replacement([0, 1], 2))))   # 3
