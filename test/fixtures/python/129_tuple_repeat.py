# Regression: `tuple * int` raised ArithmeticError — only str and
# list had repetition clauses in `py_mult/2`. Python's semantics:
# `(1, 2) * 3 == (1, 2, 1, 2, 1, 2)`. Added clauses mirroring the
# list shape (Tuple.to_list → duplicate → concat → to_tuple).

# Right-multiplication.
print((1, 2) * 3)               # (1, 2, 1, 2, 1, 2)
print((0,) * 5)                  # (0, 0, 0, 0, 0)

# Left-multiplication.
print(3 * ("a", "b"))            # ('a', 'b', 'a', 'b', 'a', 'b')

# Zero / negative — Python returns empty tuple.
print((1, 2) * 0)                # ()
print((1, 2) * -3)               # ()

# Common idiom: fixed-size zero-init buffer of tuples.
grid = ((0, 0),) * 3
print(grid)                      # ((0, 0), (0, 0), (0, 0))
