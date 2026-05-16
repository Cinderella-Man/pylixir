# Regression: a `def name(...)` defined in both branches of an
# `if/else` was emitted as `name = fn ... end` per branch (via the
# nested-FunctionDef path), but `LoopAnalysis.names_assigned_in/1`
# didn't recognise FunctionDef as a binding, so the if/else state
# tuple didn't thread `name` out — references in the post-if body
# saw "undefined variable". Fix: add a FunctionDef clause to
# names_assigned_in so def-in-branch behaves like assign-in-branch
# for the threading machinery. Adapted from an eval-corpus failure
# (compile_quoted_raised, 2026-05-16).
flag = True
n = 3

if flag:
    def check(i):
        return i % 2 == 0
else:
    def check(i):
        return i % 2 == 1

for i in range(n):
    print(check(i))

# Mixed: only one branch defines the helper, the other inherits from
# a prior scope. We don't try to compile this version because it
# changes the if-else "names assigned in both branches" balance —
# but the bidirectional case above is the failure mode we hit.
