# Regression: `bisect.bisect_left(a, x, lo)` (3-arg form, hi defaults
# to len(a)) raised `unsupported--Call` because Bisect.call/4 only had
# 2-arg and 4-arg clauses. Adapted from an eval-corpus failure
# (synthetic_sft sample 1007, 2026-05-18).
import bisect

a = [1, 3, 5, 7, 9, 11, 13]

# 3-arg: search [lo, len(a)). `7` lives at index 3, so leftmost
# insert beyond lo=2 still finds it at 3.
print(bisect.bisect_left(a, 7, 2))   # 3
print(bisect.bisect_right(a, 7, 2))  # 4
print(bisect.bisect(a, 7, 2))        # 4 (alias for bisect_right)

# lo past the value pushes the search window forward.
print(bisect.bisect_left(a, 7, 4))   # 4 (7 is now below the window)
print(bisect.bisect_left(a, 100, 2)) # 7 (everything in [2,7) is less)
