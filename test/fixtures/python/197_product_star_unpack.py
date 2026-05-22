# Regression: `itertools.product(*list_of_iterables)` — a starred
# (splat) argument whose runtime list IS the list-of-iterables.
# Previously lowered to `apply(product_fn/1, xs)`, which spreads `xs`
# as separate positional args and crashed with BadArityError. The
# starred list must be passed straight to py_product. Adapted from an
# eval-corpus BadArityError (seed_23609).
from itertools import product

# Splat over a dynamically-built list of option lists.
option_lists = [['a', 'b'] for _ in range(2)]
combos = []
for combo in product(*option_lists):
    combos.append(''.join(combo))
print(combos)  # ['aa', 'ab', 'ba', 'bb']

# Splat with a single inner list.
print(list(product(*[[1, 2, 3]])))  # [(1,), (2,), (3,)]

# Plain (non-starred) positional form still works.
print(list(product([0, 1], ['x', 'y'])))  # [(0,'x'),(0,'y'),(1,'x'),(1,'y')]

# Indexing into a product tuple, mirroring the corpus shape.
opts = [['4', '7'], ['4', '7']]
total = 0
for combo in product(*opts):
    if combo[0] == combo[1]:
        total += 1
print(total)  # 2
