# Regression: `from heapq import heappush, heappop, heapify` was
# rejected because bare-Name aliases wrap a runtime helper that
# returns the new heap, but the rebind logic that handles
# `heapq.heappush(h, x)` only matched the `heapq.X(...)` shape.
# Fix: stdlib_aliases-tracking already records the alias origin;
# Assign-target preprocessing rewrites the bare-Name Call into the
# `heapq.X(...)` shape, and `heapq_statement_mutation` recognises
# the bare form too. So `from heapq import ...` now matches the
# semantics of `import heapq; heapq.X(...)`. Adapted from an
# eval-corpus failure (unsupported--ImportFrom, 2026-05-16).
from heapq import heappush, heappop, heapify

# Pylixir's heap rep is a sorted list (not Python's binary-tree
# array), so we don't assert on the internal layout — only that
# `heappop` returns elements in min-first priority order via the
# capture-return form `x = heappop(h)` (which goes through Pylixir's
# stdlib_aliases rewrite + single_target_assign destructure).
h = []
heappush(h, 3)
heappush(h, 1)
heappush(h, 4)
heappush(h, 1)
heappush(h, 5)

x = heappop(h)
print(x)            # 1
x = heappop(h)
print(x)            # 1
x = heappop(h)
print(x)            # 3
x = heappop(h)
print(x)            # 4
x = heappop(h)
print(x)            # 5

# heapify rebinds in place (statement-context).
h2 = [5, 3, 8, 1, 9, 2]
heapify(h2)
y = heappop(h2)
print(y)            # 1

# heappush + statement-context heappop in a loop — top-3 pattern.
# Note: heappop in statement (Expr) position doesn't rebind via the
# bare-Name path yet, so we use the capture form to discard the value.
top3 = []
for v in [9, 1, 7, 3, 5, 2, 8]:
    heappush(top3, v)
    if len(top3) > 3:
        _ = heappop(top3)
print(sorted(top3))  # [7, 8, 9]
