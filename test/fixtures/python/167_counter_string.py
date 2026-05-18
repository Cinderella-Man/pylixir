# Silent bug: `Counter(some_string)` transpiled cleanly but crashed
# at runtime because `Enum.frequencies/1` doesn't accept BitString
# (Pylixir's String backing). The fix routes the arg through
# `py_iter_to_list` first, normalising strings to graphemes the same
# way `list(s)` already does. Caught while writing fixture 166.
from collections import Counter

# Direct string — was the crash trigger.
c = Counter("aabbcc")
print(c["a"])      # 2
print(c["b"])      # 2
print(c["c"])      # 2

# Tuple / list arg still works (regression check).
print(Counter([1, 1, 2])[1])           # 2
print(Counter((3, 3, 3, 4))[3])        # 3
