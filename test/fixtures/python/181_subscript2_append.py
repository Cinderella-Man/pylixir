# Regression: `adj[i][j].append(x)` — a depth-2 Subscript receiver
# in front of a list-mutation method — was rejected with the
# misleading "method `.append()` is not supported" (the list of
# allowed methods enumerated dict/string/set ops, hiding the real
# limitation). `Pylixir.Nodes.Mutations.detect/1` only recognised
# depth-1 (`coll[i].method(args)`). Common shape in adjacency-list
# patterns produced by `adj = [[[] for _ in range(n)] for _ in
# range(n)]; adj[i][j].append(edge)`. Fix: a `:subscript2` detect
# clause + `emit_subscript2/8` that lowers to a nested `py_setitem`
# (outer + inner rebind). The mirror `mutates_name?` clause in
# `ModuleAnalysis` keeps the literal-mutation rejection accurate
# for the deeper shape.

n = 3
adj = [[[] for _ in range(n)] for _ in range(n)]
adj[0][1].append((1, 2, 7))
adj[1][2].append((9, 9, 9))
adj[0][1].append((3, 4, 5))
# Indexable, mutable, AND propagates back to the outer list.
print(adj[0][1])  # [(1, 2, 7), (3, 4, 5)]
print(adj[1][2])  # [(9, 9, 9)]
print(adj[2][0])  # []
