# Regression: walrus `(n := expr)` (PEP 572) raised "NamedExpr is
# not supported". Fix: NamedExpr now lowers to Elixir's `=` which is
# already both an assignment AND a value-producing expression — exact
# semantic match for what walrus does in Python. Target must be a
# bare Name (the only shape Python permits).

# Classic use: bind once + test in same expression.
if (n := 5) > 0:
    print(n)                              # 5

# Inside while.
xs = [1, 2, 3, 4, 5]
i = 0
while (x := xs[i]) < 4:
    print(x)
    i += 1

# Walrus that gets used twice (avoiding recomputation of cost).
def cost(x):
    return x * x

values = [1, 2, 3]
for v in values:
    if (c := cost(v)) > 1:
        print(v, c)

# Walrus inside boolean short-circuit.
xs2 = [10, 20]
if (length := len(xs2)) and length > 0:
    print(length)                          # 2
