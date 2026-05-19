# Regression: tightening `collect_assigned_names` (used by closure
# demotion) to exclude Subscript targets revealed a latent bug — a
# `def find(u): while parent[u] != u: parent[u] = parent[parent[u]];
# u = parent[u]; return u` over a top-level `parent = list(range(n+1))`
# closed over `parent` AND mutated it through subscript-assign. The
# old code put "parent" into `find`'s locals (via the shared
# `target_names/1` Subscript clause), so demotion missed it, and a
# top-level `defp find(u)` referencing a runtime-only `parent`
# blew up at compile time with `undefined variable "parent"`.
# Fix has two parts: (1) `binding_target_names/1` (Name/Tuple/List/
# Starred only) for local detection, so the Subscript-mutating def
# IS detected as closing over `parent`; (2) loud
# `UnsupportedNodeError(node_type: "Module")` for any
# runtime-valued module binding that's mutated inside a top-level
# def, since the demoted closure can't propagate writes back.
# This fixture exercises the READ-only side of the same lowering —
# closing over a runtime-valued list is still legitimate and must
# keep working.

n = 5
table = list(range(n + 1))  # runtime init (Call value, not literal)


def lookup(i):
    # Reads `table` but never mutates it — the closure-demoted
    # `lookup = fn i -> ... end` inside py_main captures `table` by
    # value, which is exactly the correct semantics here.
    return table[i] * 2


print(lookup(2))  # 4
print(lookup(4))  # 8
