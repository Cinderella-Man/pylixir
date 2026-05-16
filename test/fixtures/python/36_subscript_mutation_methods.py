# Regression: `adj[A].append(B)` raised "method `.append()` is not
# supported" — the Mutations classifier only recognised bare-Name
# targets (`xs.append(x)`), so `coll[i].method(args)` fell through
# to the expression-context AttributeMethods dispatcher, which
# doesn't carry the mutation rewrites. Also: ModuleAnalysis missed
# the new shape and would have promoted `adj` to a module attribute.
# Fix: `Mutations.detect/1` now also classifies the depth-1 subscript
# shape; `ModuleAnalysis.mutates_name?/2` recognises it as a mutation
# of the root. Adapted from an eval-corpus failure (unsupported--Call,
# 2026-05-16).

# Build an adjacency list, mutate via subscript-rooted .append.
adj = [[], [], []]
adj[0].append(10)
adj[0].append(20)
adj[1].append(30)
for row in adj:
    print(row)

# Same shape across other mutation methods.
counts = [0, 0]
counts[0] = counts[0] + 1  # AugAssign on subscript still works (T14)
buckets = [[], []]
buckets[1].extend([100, 200, 300])
print(buckets[0])
print(buckets[1])
