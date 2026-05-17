# Regression: `(1, 2) + (3, 4)` crashed with ArithmeticError —
# `py_add/2` had no tuple+tuple clause, so it fell through to the
# generic `a + b` arm which tried `:erlang.+/2` on tuples. Python:
# `(1, 2, 3, 4)`. Fix: round-trip through lists for the concat.

print((1, 2) + (3, 4))                # (1, 2, 3, 4)
print(("a",) + ("b", "c"))             # ('a', 'b', 'c')
print(() + (1,))                       # (1,)
print((1,) + ())                       # (1,)
print((1, 2) + (3,) + (4, 5))          # (1, 2, 3, 4, 5)

# In an expression context.
xs = (10, 20)
ys = (30, 40)
print(xs + ys)                         # (10, 20, 30, 40)
print(len(xs + ys))                    # 4
