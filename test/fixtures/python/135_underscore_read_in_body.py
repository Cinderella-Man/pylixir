# Regression: Python's `_` is a regular variable (`for _ in range(T):
# print(_)` is legal), but Pylixir's lowering emitted Elixir's bare
# `_` (the discard pattern). Elixir's `_` is pattern-only, so any
# read of `_` inside the loop body (e.g. `[(a + _) for a in A]`)
# crashed at compile-time with "invalid use of _". Fix: rewrite all-
# underscore Python names (`_`, `__`, `___`, ...) to `_us`/`_us2`/...
# in `Pylixir.Naming` — valid Elixir identifiers that suppress
# unused-variable warnings via the `_` prefix AND are usable as
# values. `LoopAnalysis.discard_name?` still excludes them from
# state-tuple threading.

# `_` read inside the loop body (the eval-corpus repro).
T = 4
A = [10, 20, 30]
for _ in range(T):
    out = [(a + _) for a in A]
    print(out)

# `_` used outside a list comp.
for _ in range(3):
    print(_)

# Standard discard — body doesn't read `_`. Still legal.
for _ in range(3):
    pass
print("done")

# Tuple-target `_` mixed with real names.
pairs = [(1, "a"), (2, "b"), (3, "c")]
for _, name in pairs:
    print(name)
