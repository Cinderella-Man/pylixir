# Regression: slice-assignment forms `coll[start:stop] = new_seq` and
# `coll[start:stop:step] = new_seq` raised "Slice is not supported".
# Fix: the Subscript-target Assign clause now dispatches on slice
# shape; non-Slice keeps the existing py_setitem path, Slice routes
# through a new `py_slice_assign/5` runtime helper. Contiguous (no
# step) allows arbitrary new_seq length (extends/shrinks the
# collection); stepped requires len match. Adapted from eval-corpus
# failures (unsupported--Slice, 2026-05-16).

# Contiguous slice assignment — replace a span.
xs = [1, 2, 3, 4, 5]
xs[1:3] = [20, 30, 40]      # extends from 5 to 6 elements
print(xs)

# Suffix slice assignment.
ys = [10, 20, 30, 40, 50]
ys[2:] = [99]               # shrinks to [10, 20, 99]
print(ys)

# Stepped slice assignment (sieve idiom).
sieve = [True] * 12
sieve[4:12:2] = [False] * 4
print(sieve)

# Prefix slice assignment.
zs = [1, 2, 3, 4, 5]
zs[:2] = []                 # remove first two
print(zs)
