# Regression: `n, *rest = ...` (star-unpack destructure) raised
# "star-unpack inside a Tuple literal is not supported". Fix:
# `single_target_assign` for Tuple targets now partitions on the
# starred element. Prefix Names and suffix Names go through
# `Enum.split`; the star captures the middle. Pylixir's deque-rep
# lists let this work directly with Python's list/tuple destructure
# semantics. Adapted from an eval-corpus failure
# (unsupported--Starred, 2026-05-16).

# Common form: first N elements + tail.
n, *rest = [1, 2, 3, 4, 5]
print(n)      # 1
print(rest)   # [2, 3, 4, 5]

# Two prefix names + star.
a, b, *tail = "abcdef"
print(a)      # a
print(b)      # b
print(tail)   # ['c', 'd', 'e', 'f']

# Star alone — just bind everything to a list.
*xs, = (10, 20, 30)
print(xs)     # [10, 20, 30]

# Star in the middle: prefix + middle + suffix.
first, *mid, last = [1, 2, 3, 4, 5]
print(first)  # 1
print(mid)    # [2, 3, 4]
print(last)   # 5

# Star empty middle case.
first, *mid, last = [10, 20]
print(first)  # 10
print(mid)    # []
print(last)   # 20
