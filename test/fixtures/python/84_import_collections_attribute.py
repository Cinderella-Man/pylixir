# Regression: `import collections` raised "no stdlib translation".
# `from collections import deque, Counter, defaultdict` was supported
# (silent no-op + bare-Name builtin dispatch), but the namespaced form
# `collections.Counter(...)` wasn't. Fix: registered
# `Pylixir.Stdlib.Collections` that delegates the Counter/defaultdict/
# deque attribute-calls to `Pylixir.Builtins` (single lowering shared
# between the bare-Name and `collections.<Name>` paths). Adapted from
# an eval-corpus failure (unsupported--Import, 2026-05-16).
import collections

# Counter via the namespaced form.
chars = ["a", "b", "a", "c", "b", "a"]
freq = collections.Counter(chars)
print(freq["a"])     # 3
print(freq["b"])     # 2
print(freq["c"])     # 1

# defaultdict via namespaced form (int default).
counts = collections.defaultdict(int)
for k in ["a", "b", "a", "a"]:
    counts[k] += 1
print(counts["a"], counts["b"])  # 3 1

# deque via namespaced form.
q = collections.deque([1, 2, 3])
q.append(4)
print(list(q))

# Bare-Name forms still work via Builtins (regression check).
from collections import Counter
c2 = Counter(["s", "s", "i", "i", "i", "i", "s", "s"])
print(c2["s"])       # 4
print(c2["i"])       # 4
