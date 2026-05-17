# Regression: `def comb(...): ... fact[...] ...` is demoted to a
# closure because it references mutable top-level state (`fact`,
# `inv_fact`). `def main(): ... comb(...) ...` was kept as a `defp`,
# but the closure-bound `comb` only exists inside py_main's scope so
# the `defp main` couldn't see it. Fix: demote_closures now iterates
# to a fix-point — any function referencing an already-demoted name
# also demotes. Adapted from an eval-corpus failure
# (compile_quoted_raised, 2026-05-16).
fact = [1, 1, 2, 6, 24, 120]

# Closes over `fact` (mutable) → demoted to a closure.
def comb(n, k):
    if k < 0 or k > n:
        return 0
    return fact[n] // (fact[k] * fact[n - k])

# Transitively closes over `comb` → also demoted (fix-point pass).
def main():
    print(comb(5, 2))    # 10
    print(comb(5, 0))    # 1
    print(comb(5, 5))    # 1
    print(comb(5, 6))    # 0

main()
