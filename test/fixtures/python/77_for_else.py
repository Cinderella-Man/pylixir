# Regression: Python's `for ... else:` clause (the `else` runs iff the
# loop completed without `break`) raised "for/else is not supported".
# Fix: `emit_for_else` wraps the loop's reduce/each in a try that
# returns `{state, broke?}` — `{state, false}` on normal completion,
# `{payload, true}` on break. Then `unless broke?, do: else_block`.
# Adapted from an eval-corpus failure (unsupported--For, 2026-05-16).

# Else runs (no break).
def has_no_zero(xs):
    for x in xs:
        if x == 0:
            return False
    else:
        return True

print(has_no_zero([1, 2, 3]))     # True
print(has_no_zero([1, 0, 3]))     # False

# else skipped on break — capture into a threaded var instead of
# relying on the for-target leaking out (which Pylixir's for-emission
# intentionally doesn't support; see lib/pylixir/loop_analysis.ex).
def first_index(xs, target):
    found = -1
    for i, x in enumerate(xs):
        if x == target:
            found = i
            break
    else:
        return -1
    return found

print(first_index([10, 20, 30], 20))   # 1
print(first_index([10, 20, 30], 99))   # -1

# Primality via for/else (the canonical Python idiom).
def is_prime(n):
    if n < 2:
        return False
    for d in range(2, n):
        if n % d == 0:
            return False
    else:
        return True

print(is_prime(2))    # True
print(is_prime(4))    # False
print(is_prime(13))   # True
print(is_prime(15))   # False
