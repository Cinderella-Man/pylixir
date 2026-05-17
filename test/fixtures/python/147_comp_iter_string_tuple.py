# Regression: comprehensions iterating a string or tuple
# (`{c for c in "abc"}`, `[x for x in (1, 2, 3)]`) crashed at
# runtime with `Protocol.UndefinedError: Enumerable not implemented
# for BitString/Tuple`. Comp lowering emitted `Enum.map(iter, fn)`
# directly without coercion, so anything that isn't natively
# Enumerable bombed. Fix: wrap the comp's iter with
# `py_iter_to_list/1` (no-op for lists, graphemes for strings,
# `Tuple.to_list` for tuples, `Map.keys` for dicts). Same treatment
# as the for-loop iter (fixture 146).

# Set comp from a string.
print(sorted({c.upper() for c in "hello"}))         # ['E', 'H', 'L', 'O']

# List comp from a string.
print([c.lower() for c in "ABC"])                    # ['a', 'b', 'c']

# Dict comp building from .items() (already entry-shaped).
print(sorted({k: v*v for k, v in {"a": 2, "b": 3}.items()}.items()))
# [('a', 4), ('b', 9)]

# List comp from a tuple.
print([x*2 for x in (1, 2, 3)])                      # [2, 4, 6]

# Set comp from a tuple.
print(sorted({x % 3 for x in (10, 11, 12, 13, 14)})) # [0, 1, 2]

# Comp iter over a dict (yields keys, like for-loop).
print(sorted([k for k in {"x": 1, "y": 2}]))         # ['x', 'y']
