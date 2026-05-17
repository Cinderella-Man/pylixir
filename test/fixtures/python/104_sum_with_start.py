# Regression: `sum(iter, start)` (2-arg form) raised "`sum/2` is not
# a supported Python builtin call shape" — only `sum(iter)` was
# handled. Fix: added a 2-arg `emit("sum", [xs, start], _kw)` clause
# that threads `start` as the Enum.reduce initial accumulator instead
# of 0.

# Standard sum still works.
print(sum([1, 2, 3]))               # 6

# 2-arg form with non-zero start.
print(sum([1, 2, 3], 100))          # 106
print(sum([], 42))                  # 42 (empty iter returns start)
print(sum(range(10), 1000))         # 1045

# Common idiom: list concat via sum + empty-list start (Python emits
# a warning for this but supports it).
print(sum([[1, 2], [3, 4]], []))    # [1, 2, 3, 4]
