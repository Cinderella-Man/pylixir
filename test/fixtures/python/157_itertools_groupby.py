# Regression: `from itertools import groupby` was rejected at
# transpile time. Loop 4 of the eval-corpus work wires it up: the
# stdlib lowers each `(key, group)` pair to a 2-tuple via
# `py_itertools_groupby/1`, which mirrors Python's "group consecutive
# equal elements" semantics on top of `Enum.chunk_by/2`. The `key=`
# kwarg form also routes to `py_itertools_groupby_key/2`.

from itertools import groupby

# Consecutive equal grouping on a string (Python iterates strings
# as characters; `py_iter_to_list` normalises).
for k, g in groupby("aaabbcccdde"):
    print(k, len(list(g)))

# Run-length encoding via a list comprehension.
print([(k, len(list(g))) for k, g in groupby("aaabb")])

# `key=` kwarg form.
nums = [1, 1, 2, 2, 2, 3, 1, 1]
print([(k, list(g)) for k, g in groupby(nums)])

# `key=` with a predicate (parity).
print([(k, list(g)) for k, g in groupby([1, 3, 5, 2, 4, 7, 9], key=lambda n: n % 2)])
