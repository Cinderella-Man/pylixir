# Regression: in-place set updates `s.intersection_update(other)`,
# `s.difference_update(other)`, `s.symmetric_difference_update(other)`
# all raised "mutation method `.X(1 args)` is not supported". Added
# clauses in `Pylixir.Nodes.Mutations` lowering to the matching
# MapSet ops (symmetric_difference composes via two differences +
# union, same as the AttributeMethods set arm). The mutation-method
# lists in `LoopAnalysis` and `ModuleAnalysis` got the same entries
# so threading + module-attr demotion stay correct.

# intersection_update.
s = {1, 2, 3, 4}
s.intersection_update({2, 3, 5})
print(sorted(s))                        # [2, 3]

# difference_update.
s = {1, 2, 3, 4, 5}
s.difference_update({2, 4})
print(sorted(s))                        # [1, 3, 5]

# symmetric_difference_update.
s = {1, 2, 3}
s.symmetric_difference_update({2, 3, 4})
print(sorted(s))                        # [1, 4]

# Inside a loop body — exercises the LoopAnalysis threading.
def filter_sets(targets, candidates):
    keep = set(targets)
    for c in candidates:
        keep.intersection_update(c)
    return keep

result = filter_sets({1, 2, 3, 4, 5}, [{2, 3, 4, 5}, {3, 4, 5, 6}, {4, 5, 6, 7}])
print(sorted(result))                   # [4, 5]
