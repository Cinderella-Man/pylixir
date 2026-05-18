# Regression: a demoted top-level def whose body called *another*
# demoted sibling defined LATER in source produced "undefined
# function" at Elixir compile time — the call was lowered as a
# top-level defp invocation, but the callee was emitted as a closure
# binding inside py_main and the caller couldn't reach it.
#
# Fix has three parts: (1) emit `name.(args)` (closure call) for
# names in `Context.demoted_functions`; (2) thread demoted-fn refs
# as additional params to extracted `defp while_N` helpers so the
# body can call them; (3) topologically sort each run of consecutive
# demoted defs so the closure exists when the caller's `fn` body is
# created. Adapted from a compile_error--compile_quoted_raised
# sample (synthetic_sft id 1045, 2026-05-18).

# Both demoted because they close over `comb` from `import math`,
# which is a runtime binding (`comb = fn ... end` inside py_main).
from math import comb

def caller(n):
    # Calls `callee`, defined AFTER this point in source order.
    # Topological sort emits callee first; caller's fn body then
    # captures callee's closure cleanly.
    total = 0
    i = 0
    while i < n:
        total += callee(i)
        i += 1
    return total

def callee(i):
    return comb(i + 2, 2)

print(caller(5))  # comb(2,2)+comb(3,2)+comb(4,2)+comb(5,2)+comb(6,2) = 1+3+6+10+15 = 35
