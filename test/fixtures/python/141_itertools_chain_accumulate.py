# Regression: `itertools.chain`, `itertools.accumulate`,
# `itertools.repeat`, `itertools.takewhile`, `itertools.dropwhile`
# were all unsupported. Added clauses + runtime helpers
# (`py_itertools_chain/1`, `py_itertools_accumulate/1`).
# repeat/takewhile/dropwhile route to existing Enum / List functions.

import itertools

# chain.
print(list(itertools.chain([1, 2], [3, 4], [5])))   # [1, 2, 3, 4, 5]
print(list(itertools.chain("ab", "cd")))            # ['a', 'b', 'c', 'd']
print(list(itertools.chain()))                       # []

# chain.from_iterable.
print(list(itertools.chain.from_iterable([[1, 2], [3, 4]])))  # [1, 2, 3, 4]

# accumulate — running sums.
print(list(itertools.accumulate([1, 2, 3, 4])))     # [1, 3, 6, 10]
print(list(itertools.accumulate([])))               # []
print(list(itertools.accumulate([5])))              # [5]

# accumulate with custom func.
print(list(itertools.accumulate([1, 2, 3, 4], lambda a, b: a * b)))  # [1, 2, 6, 24]

# repeat (bounded).
print(list(itertools.repeat("x", 3)))               # ['x', 'x', 'x']
print(list(itertools.repeat(0, 5)))                 # [0, 0, 0, 0, 0]

# takewhile.
print(list(itertools.takewhile(lambda x: x < 5, [1, 4, 6, 4, 1])))   # [1, 4]
print(list(itertools.takewhile(lambda x: x > 0, [1, 2, 3])))         # [1, 2, 3]

# dropwhile.
print(list(itertools.dropwhile(lambda x: x < 5, [1, 4, 6, 4, 1])))   # [6, 4, 1]

# from-import paths.
from itertools import chain, accumulate, takewhile
print(list(chain([1], [2, 3])))                     # [1, 2, 3]
print(list(accumulate([1, 1, 1])))                  # [1, 2, 3]
print(list(takewhile(lambda x: x != 3, [1, 2, 3, 4])))  # [1, 2]
