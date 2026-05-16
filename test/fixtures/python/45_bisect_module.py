# Regression: `import bisect` raised "no stdlib translation". Fix:
# new `Pylixir.Stdlib.Bisect` registered alongside math + sys,
# routing `bisect.bisect_left/right` to runtime helpers backed by
# `Enum.find_index`. Adapted from an eval-corpus failure
# (unsupported--Import, 2026-05-16).
import bisect

sorted_list = [1, 3, 5, 7, 9]

print(bisect.bisect_left(sorted_list, 4))   # 2
print(bisect.bisect_left(sorted_list, 5))   # 2 (leftmost for equal)
print(bisect.bisect_right(sorted_list, 5))  # 3 (rightmost)
print(bisect.bisect_left(sorted_list, 0))   # 0
print(bisect.bisect_left(sorted_list, 100)) # 5

# `bisect` is alias for `bisect_left`.
print(bisect.bisect(sorted_list, 6))        # 3
