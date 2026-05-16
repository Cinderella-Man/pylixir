# Regression: `from math import gcd, sqrt` raised
# `UnsupportedNodeError("ImportFrom")`. Fix: emit each imported name
# as a local lambda delegating to the matching `Pylixir.Stdlib.Math`
# AST, then the subsequent `gcd(t, n)` resolves via the in-scope
# anonymous-fn-call path. Adapted from an eval-corpus failure
# (unsupported--ImportFrom, 2026-05-16).
from math import gcd, sqrt, floor

print(gcd(12, 8))
print(int(sqrt(16)))
print(floor(3.7))

# Direct iteration usage — the bare name `gcd` is in scope.
nums = [24, 36, 60]
acc = nums[0]
for x in nums[1:]:
    acc = gcd(acc, x)
print(acc)
