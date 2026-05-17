# Regression: `zip(*mat)` (star-unpack in call args) and
# `is_valid_triplet(*triplet)` raised "Starred is not supported".
# Fix: `emit_name_call` detects the common single-Starred form. For
# `zip`, lower to `Enum.zip(arg)` (Enum.zip natively handles a list
# of iterables — same semantics as Python's zip(*xs)). For in-scope
# lambdas (or top-level defs), emit `apply(fn, py_iter_to_list(args))`.
# Adapted from eval-corpus failures (unsupported--Starred, 2026-05-16).

# `zip(*mat)` — transpose idiom. mat is a list of equal-length rows.
mat = [
    [1, 2, 3],
    [4, 5, 6],
    [7, 8, 9],
]

for col in zip(*mat):
    # col is a tuple in Python (Enum.zip yields tuples); index each
    # element to print regardless of container.
    print(col[0], col[1], col[2])

# Star-unpack on a lambda binding — apply(fn, args) works.
is_triplet_sorted = lambda a, b, c: a <= b <= c

triplet = (1, 2, 3)
print(is_triplet_sorted(*triplet))     # True

triplet2 = (3, 1, 2)
print(is_triplet_sorted(*triplet2))    # False

# Star-unpack on a lambda directly bound to a name.
sum3 = lambda a, b, c: a + b + c
print(sum3(*[10, 20, 30]))             # 60
