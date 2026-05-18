# Regression: `obj.outer.inner += val` (depth-2 attribute AugAssign)
# raised unsupported--AugAssign. Now lowered as a nested Map.put /
# Map.fetch! chain — rebinds the root so the updated value is
# observable through chained reads. Aliasing semantics differ from
# Python: multiple references to the same `obj.outer` won't observe
# each other's updates (Pylixir's instance maps are immutable). For
# the common single-owner case (the eval-corpus shape — Tarjan's
# suffix automaton building a chain of State nodes), the lowering
# matches Python's behavior. Adapted from synthetic_sft sample 1075
# (2026-05-18).
class Inner:
    def __init__(self, v):
        self.cnt = v

class Outer:
    def __init__(self):
        self.inner = Inner(10)

o = Outer()
o.inner.cnt += 5
o.inner.cnt += 3
print(o.inner.cnt)       # 18

# Read-only chained access also works (the same Map.fetch! chain).
print(o.inner.cnt + 1)   # 19
