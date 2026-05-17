# Regression: `str.rsplit(sep, maxsplit)` lowered to `String.split`
# with `parts:` which is LEFT-anchored — but Python's rsplit groups
# the leftmost chunk, not the rightmost. Added a true right-anchored
# `py_str_rsplit/3` (reverse + split + reverse). Zero/no-maxsplit
# forms still route to `String.split` directly (equivalent there).

# No maxsplit — same as split.
print("a,b,c,d".rsplit(","))             # ['a', 'b', 'c', 'd']

# maxsplit=1 — the leftmost chunk grows; rightmost stays singular.
print("a,b,c,d".rsplit(",", 1))          # ['a,b,c', 'd']

# maxsplit=2.
print("a,b,c,d,e".rsplit(",", 2))        # ['a,b,c', 'd', 'e']

# maxsplit larger than splits available.
print("a.b".rsplit(".", 5))              # ['a', 'b']

# Multi-character separator.
print("aXXbXXcXXd".rsplit("XX", 1))      # ['aXXbXXc', 'd']
