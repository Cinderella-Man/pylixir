# Regression: `from functools import cmp_to_key` was rejected
# at transpile time. Loop 5 of the eval-corpus work wires it up:
# `cmp_to_key` binds to a lambda that tags its arg as
# `{:py_cmp_to_key, cmp}`, and the `sorted(...)` lowering now
# routes the `key=` kwarg through `py_sorted_by/2` (and
# `py_sorted_by_desc/2` for `reverse=True`). The runtime helper
# pattern-matches the tagged shape and uses `Enum.sort/2` with a
# 2-arity comparator (`cmp.(a, b) <= 0`) instead of `Enum.sort_by/2`
# with a 1-arity key. Plain `key=<fn>` still falls through to
# `Enum.sort_by` as before.

from functools import cmp_to_key

# Classic "largest number" assembly: sort strings so concatenation
# yields the lexically biggest combined value.
nums = ["3", "30", "34", "5", "9"]
ordered = sorted(nums, key=cmp_to_key(
    lambda a, b: -1 if a + b > b + a else (1 if a + b < b + a else 0)
))
print("".join(ordered))                    # 9534330

# Descending by absolute value via a comparator.
xs = [-3, 1, -4, 2, -5]
print(sorted(xs, key=cmp_to_key(lambda a, b: abs(b) - abs(a))))
# [-5, -4, -3, 2, 1]

# Combine cmp_to_key with reverse=True — the comparator inverts.
print(sorted([1, 5, 3, 2, 4],
             key=cmp_to_key(lambda a, b: a - b),
             reverse=True))
# [5, 4, 3, 2, 1]

# Plain `key=<fn>` still works (must not be regressed by the
# routing change).
print(sorted([3, 1, 4, 1, 5, 9, 2, 6]))            # [1, 1, 2, 3, 4, 5, 6, 9]
print(sorted(["banana", "apple", "cherry"], key=len))
