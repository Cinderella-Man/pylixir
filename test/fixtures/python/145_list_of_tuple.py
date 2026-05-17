# Regression: `list((1, 2, 3))` raised
# `Protocol.UndefinedError: Enumerable not implemented for Tuple`.
# Fix: route the `list(iter)` builtin through `py_iter_to_list/1`
# which already handles tuples (via `Tuple.to_list`), strings
# (per-grapheme), maps (to entry list), and everything Enum handles.

# Tuple → list — was crashing.
print(list((1, 2, 3)))           # [1, 2, 3]
print(list((42,)))                # [42]
print(list(()))                   # []

# String → list of graphemes.
print(list("abc"))                # ['a', 'b', 'c']

# Range / map / set still work.
print(list(range(3)))             # [0, 1, 2]
print(list(map(str, [1, 2, 3])))  # ['1', '2', '3']
print(sorted(list({3, 1, 2})))    # [1, 2, 3]

# Dict → list of keys (Python's iteration default).
d = {"a": 1, "b": 2}
print(sorted(list(d)))            # ['a', 'b']
