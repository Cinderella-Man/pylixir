# Regression: `sieve[0] = sieve[1] = False` (multi-target Assign with
# Subscript targets) raised "multi-target Assign requires all targets
# to be `Name` nodes; got `Subscript`". Fix: `multi_target_assign` now
# also accepts Subscript-on-Name targets, threading py_setitem rebinds
# in source order. The RHS is single-evaluated when non-trivial (Python
# semantics: `a = b = expensive()` calls expensive once). Adapted from
# an eval-corpus failure (unsupported--Assign, 2026-05-16).

# Sieve init using chained Subscript Assign.
sieve = [True] * 10
sieve[0] = sieve[1] = False
print(sieve)

# Chained with three targets, mixing Name and Subscript.
xs = [0, 0, 0]
val = xs[0] = xs[2] = 99
print(val)
print(xs)

# Single-eval RHS check: the RHS value lands in both slots and they
# share the same evaluated value (just print to confirm both got it).
ys = [None, None, None]
ys[0] = ys[2] = 42 + 8
print(ys)        # [50, None, 50]
