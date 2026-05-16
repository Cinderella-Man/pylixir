# Regression: `from collections import deque` raised
# `UnsupportedNodeError("ImportFrom")` and `q.popleft()` had no
# rewrite. Fix: ImportFrom now allows `from collections import deque`
# (silent no-op); `deque()` / `deque(iter)` are translated as builtins
# backed by a plain Elixir list; `x = q.popleft()` becomes a
# cons-pattern destructure (`[x | q] = q`). Adapted from an
# eval-corpus failure (unsupported--Call, 2026-05-16).
from collections import deque

q = deque()
q.append(1)
q.append(2)
q.append(3)

# popleft inside a BFS-style loop.
while q:
    head = q.popleft()
    print(head)

# Constructor with iterable + length probe via len().
q2 = deque([10, 20, 30])
print(len(q2))
print(q2[0])
