# Silent bug: `sep.join(some_string)` crashed at runtime because
# `Enum.join` doesn't accept BitString. Python's `",".join("abc")`
# returns `"a,b,c"` (iterates the string grapheme-by-grapheme).
# Fix: route `items` through `py_iter_to_list`.
print(",".join("abc"))           # a,b,c
print("-".join(("x", "y", "z"))) # x-y-z

# Existing list arg keeps working (regression check).
print(", ".join(["1", "2", "3"]))  # 1, 2, 3

# deque(string) also threaded through py_iter_to_list — used to
# crash on `Enum.to_list/1` for BitString.
from collections import deque
q = deque("xyz")
print(list(q))                   # ['x', 'y', 'z']
