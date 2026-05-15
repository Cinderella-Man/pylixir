# RFC §6.4: chained comparisons should AND the pairs.
x = 5
print(1 < x < 10)
print(0 < x < 3)
print(5 <= x <= 5)
print(x < 0 or x > 100)
print(3 < x < 7 < 10)

# Edge: empty range — should yield False without raising.
print(10 < x < 5)
