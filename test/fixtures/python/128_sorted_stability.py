# Regression: `sorted(xs, key=k, reverse=True)` and `xs.sort(reverse=
# True)` were lowered as `Enum.reverse(Enum.sort_by(...))` and
# `Enum.reverse(Enum.sort(...))` — both produced REVERSE-STABLE
# output, while Python guarantees STABLE descending order. Equal-key
# elements ended up in reverse-insertion order. Fix: emit
# `Enum.sort/sort_by(..., :desc)` so the comparator itself runs in
# descending mode and stability is preserved.

# Plain reverse=True — equal elements keep order (note: 1, 1).
print(sorted([(1, "a"), (1, "b"), (2, "c")], key=lambda p: p[0], reverse=True))
# Python: [(2, 'c'), (1, 'a'), (1, 'b')]

# Reverse=True without key.
print(sorted([3, 1, 3, 2, 1], reverse=True))
# Python: [3, 3, 2, 1, 1] — identical to ascending+reverse for ints

# list.sort(reverse=True, key=...).
xs = [("a", 2), ("b", 1), ("c", 2)]
xs.sort(key=lambda p: p[1], reverse=True)
print(xs)
# Python: [('a', 2), ('c', 2), ('b', 1)]

# Multi-pass stable sort idiom (sort by secondary then primary).
records = [(1, "x"), (2, "x"), (1, "y"), (2, "y")]
records.sort(key=lambda r: r[1])     # primary by 2nd elem (ascending)
records.sort(key=lambda r: r[0], reverse=True)  # then 1st desc, stable
print(records)
# Python: [(2, 'x'), (2, 'y'), (1, 'x'), (1, 'y')]
