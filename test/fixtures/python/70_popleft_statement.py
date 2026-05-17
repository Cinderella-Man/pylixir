# Regression: `q.popleft()` as a bare statement (capture-and-discard
# form, e.g. inside a while loop pruning the front of a deque) raised
# "method `.popleft()` is not supported" — the converter only had a
# capture-return clause inside `single_target_assign`. Fix: added
# `popleft` to `Pylixir.Nodes.Mutations` so the statement form lowers
# to `q = tl(q)` (matching the deque-as-list rep, FunctionClauseError
# on empty mirrors Python's IndexError). Adapted from an eval-corpus
# failure (unsupported--Call, 2026-05-16).
from collections import deque

q = deque([1, 2, 3, 4, 5])

# Statement-context popleft — discards the head and rebinds q.
q.popleft()
q.popleft()
print(list(q))   # [3, 4, 5]

# Mixed with capture-return (existing form).
front = q.popleft()
print(front)     # 3
print(list(q))   # [4, 5]
