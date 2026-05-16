# Regression: `for row in grid: ...` inside an `if` body produced
# `row = if ... do ... row else row end` — the if's state-tuple
# wrapper tried to thread `row` through both branches, but `row` is
# scoped to the for-loop's lambda parameter in Pylixir's emission and
# isn't visible after. Fix: `LoopAnalysis.names_assigned_in/1` no
# longer tracks for-loop targets at all (the loop emitter strips
# them anyway). Adapted from an eval-corpus failure
# (compile_error--compile_quoted_raised, 2026-05-16).
grid = [[1, 2], [3, 4]]
has_sample = False

if not has_sample:
    for row in grid:
        print(row)
    print("done")
else:
    print("had sample")

# Nested for-in-if + variable threading still works for body-assigns.
total = 0
flag = True
if flag:
    for x in [1, 2, 3]:
        total += x

print(total)
