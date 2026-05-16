# Regression: `heapq.heappush(heap, item)` raised "method `.heappush()`
# is not supported" — `heapq` wasn't registered as stdlib and the call
# was misclassified as a method invocation. Fix:
#
#   1. New `Pylixir.Stdlib.Heapq` module + `py_heappush` /
#      `py_heappop` / `py_heapify` runtime helpers (backed by a sorted
#      list — O(n) vs heapq's O(log n), adequate for competitive
#      inputs).
#   2. Converter Expr clause recognises `heapq.heappush(heap, …)` /
#      `.heapify(heap)` and rebinds `heap`.
#   3. Converter Assign clause recognises `x = heapq.heappop(heap)`
#      and `(a, b) = heapq.heappop(heap)` — destructures the
#      `{head, tail}` shape `py_heappop/1` returns.
#   4. `ModuleAnalysis` + `LoopAnalysis` track the `heap`-mutation
#      so a top-level `heap = []` isn't promoted to `@var_heap`, and
#      for-loop bodies thread `heap` correctly.
#
# Adapted from an eval-corpus failure (unsupported--Call, 2026-05-16).
import heapq

# Dijkstra-style usage: tuples ordered by first element.
heap = []
for item in [(5, "a"), (1, "b"), (3, "c"), (2, "d")]:
    heapq.heappush(heap, item)

while heap:
    dist, name = heapq.heappop(heap)
    print(dist, name)

# heapify on an existing list.
nums = [5, 1, 3, 2, 4]
heapq.heapify(nums)
print(nums[0])
