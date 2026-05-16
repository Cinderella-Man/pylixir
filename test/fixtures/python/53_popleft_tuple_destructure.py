# Regression: `x, y = queue.popleft()` raised "method `.popleft()` is
# not supported" — only the bare-Name form (`a = q.popleft()`) was
# special-cased. Fix: a parallel clause in `single_target_assign`
# handles the tuple-target case, emitting `[{x, y} | q] = q` for a
# names-only tuple destructure. Adapted from an eval-corpus failure
# (unsupported--Call, 2026-05-16).
from collections import deque

# BFS-style traversal where the deque holds coordinate pairs.
q = deque([(0, 0), (1, 2), (3, 4)])
while q:
    x, y = q.popleft()
    print(x, y)

# Triple-element variant.
q2 = deque([(1, 2, 3), (4, 5, 6)])
while q2:
    a, b, c = q2.popleft()
    print(a + b + c)
