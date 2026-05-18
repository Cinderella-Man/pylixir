# Regression: `next(iter(x))` raised `unsupported--Call` because both
# `iter` and `next` are in Pylixir's @unsupported-builtins list. The
# whole `next(iter(...))` shape is a common "first element" idiom
# though — we lower it as a single pair before arg conversion fires
# the rejection. Adapted from synthetic_sft sample 1373, 2026-05-18.
from collections import Counter

counts = Counter([1, 1, 2, 2, 3, 3]).values()
print(next(iter(counts)))   # 2

# Default-arg form: next(iter(empty), default) — Python's empty-iter
# fallback. Lowers to Enum.at/3 with the default.
print(next(iter([]), -1))   # -1
print(next(iter([7, 8]), -1))  # 7

# 1-arg over a dict's values: order is guaranteed for single-item.
# (Bare `next(iter(d))` over a dict iterates keys in Python but
# falls through Enum on Pylixir's Map backing, so we don't lower
# that shape — users can write `next(iter(d.keys()))` if they need
# the key explicitly.)
d = {"only": 42}
print(next(iter(d.values())))   # 42
