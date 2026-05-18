# Regression: `d.appendleft(x)` raised `unsupported--Call` because the
# mutation method wasn't registered. Pylixir's deque rep is an Elixir
# list, so `d = [x | d]` matches Python's O(1) leftward append.
# Adapted from an eval-corpus failure (synthetic_sft sample 1983,
# 2026-05-18).
from collections import deque

d = deque([2, 3, 4])
d.appendleft(1)
d.appendleft(0)
print(list(d))          # [0, 1, 2, 3, 4]

# Mixed: appendleft + append + popleft.
q = deque()
q.append('a')
q.appendleft('z')
q.append('b')
print(list(q))          # ['z', 'a', 'b']
q.popleft()
print(list(q))          # ['a', 'b']
