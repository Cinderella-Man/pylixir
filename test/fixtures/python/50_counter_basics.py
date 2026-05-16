# Regression: `from collections import Counter` was rejected by the
# ImportFrom guard, and `Counter(iter)` had no builtin clause. Fix:
# the collections allowlist now includes `Counter`, and the builtin
# lowers to `Enum.frequencies/1` (exact-equivalent for the common
# count-occurrences use case). Adapted from an eval-corpus failure
# (unsupported--ImportFrom, 2026-05-16).
from collections import Counter

# Constructor over a list — keys are unique items, values are counts.
freq = Counter(["a", "b", "a", "c", "b", "a"])

# Counter is a dict at the surface, so .get / [] / sorted-by-key work.
print(freq.get("a"))
print(freq.get("b"))
print(freq.get("z", 0))    # missing key with default
print(sorted(freq.keys()))

# Numeric source (the eval-corpus shape: frequency of card values).
cards = [3, 3, 7, 7, 7, 1]
card_counts = Counter(cards)
print(card_counts.get(7))
print(card_counts.get(3))
