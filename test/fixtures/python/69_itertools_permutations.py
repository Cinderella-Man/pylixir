# Regression: `itertools.permutations(iter)` and the 2-arg form
# `itertools.permutations(iter, r)` raised "is not a supported stdlib
# call". Fix: route both to a new `py_permutations` runtime helper.
# Like `py_combinations`, this returns *lists* rather than Python
# tuples — the fixture iterates and indexes/joins the items so the
# golden assertion doesn't depend on container printing convention.
# Adapted from an eval-corpus failure (unsupported--Call, 2026-05-16).
import itertools

# Full permutations of an int list — count and check first/last.
all_perms = list(itertools.permutations([1, 2, 3]))
print(len(all_perms))           # 6
print(all_perms[0][0], all_perms[0][1], all_perms[0][2])  # 1 2 3
print(all_perms[-1][0], all_perms[-1][1], all_perms[-1][2])  # 3 2 1

# r-length permutations as strings.
for p in itertools.permutations(["a", "b", "c"], 2):
    print("".join(p))

# r > len returns empty.
print(len(list(itertools.permutations([1, 2], 3))))  # 0
