# Regression: `itertools.combinations(iter, r)` raised "method
# `.combinations()` is not supported" — `itertools` wasn't a
# registered stdlib module, so the call fell through to method
# dispatch. Fix: new `Pylixir.Stdlib.Itertools` module + the
# `py_combinations/2` runtime helper. Adapted from an eval-corpus
# failure (unsupported--Call, 2026-05-16).
import itertools

# Original-corpus idiom: iterate r-length subsets.
vowels = ["a", "e", "i", "o", "u"]
for r in range(1, 3):
    for subset in itertools.combinations(vowels, r):
        print("".join(subset))

# Combination counts at each edge — counts are repr-stable across
# the list-vs-tuple difference (CPython yields tuples, Pylixir
# yields lists, but len() agrees).
print(len(list(itertools.combinations([1, 2, 3], 3))))   # 1
print(len(list(itertools.combinations([1, 2, 3], 0))))   # 1 (empty combo)
print(len(list(itertools.combinations([], 2))))           # 0
# Element-wise probe: turn each tuple/list into its sorted contents
# string — same regardless of inner container type.
print(",".join(["".join(map(str, c)) for c in itertools.combinations([1, 2, 3], 2)]))
