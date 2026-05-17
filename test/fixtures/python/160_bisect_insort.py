# Regression: `bisect.insort(xs, v)` (and `insort_left` / `insort_right`)
# were unsupported. Loops 11-20 of the eval-corpus work added them:
# `Pylixir.Stdlib.Bisect.statement_mutation_call/2` mirrors the
# heapq mutation-recognition shape, the Expr clause rebinds the
# target list (`xs = py_bisect_insort_right(xs, v)`), and
# `ModuleAnalysis` learns about the mutation so a module-top
# `xs = []` isn't wrongly promoted to `@var_xs`.

import bisect

xs = [1, 3, 5, 7]

bisect.insort(xs, 4)
print(xs)                              # [1, 3, 4, 5, 7]

bisect.insort(xs, 0)
print(xs)                              # [0, 1, 3, 4, 5, 7]

bisect.insort_left(xs, 5)
print(xs)                              # [0, 1, 3, 4, 5, 5, 7]

bisect.insort_right(xs, 5)
print(xs)                              # [0, 1, 3, 4, 5, 5, 5, 7]

# Aliased import — runtime binding routes through stdlib_aliases.
from bisect import insort, insort_left
ys = [10, 20, 30]
insort(ys, 25)
print(ys)                              # [10, 20, 25, 30]
insort_left(ys, 20)
print(ys)                              # [10, 20, 20, 25, 30]
