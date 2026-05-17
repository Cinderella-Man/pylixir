# Regression: `count, (a, b) = func()` (a Tuple target with a nested
# Tuple inside) raised "tuple-Assign with a Subscript target requires
# a literal tuple RHS" — the all-Names check failed for the nested
# Tuple, falling through to the mixed-target path. Fix: extended the
# pure-destructure check to accept nested Tuples/Lists recursively,
# and added matching bind/pattern helpers. Elixir handles nested
# tuple destructure natively (`{count, {a, b}} = func()`). Adapted
# from an eval-corpus failure (unsupported--Assign, 2026-05-16).
def divisions(n):
    return n // 2, (n % 2, n * n)

count, (rem, sq) = divisions(7)
print(count)          # 3
print(rem)            # 1
print(sq)             # 49

# Deeper nesting.
def packed():
    return 1, (2, (3, 4))

a, (b, (c, d)) = packed()
print(a, b, c, d)     # 1 2 3 4

# Nested in a for-loop target (also goes through pure-destructure).
pairs = [(1, (10, 100)), (2, (20, 200)), (3, (30, 300))]
for k, (v, w) in pairs:
    print(k, v, w)
