# Gap fill: existing fixtures use sum([x for x in xs]) (list-comp
# inside a builtin), never `sum(x for x in xs)` — a bare generator
# expression as the sole positional arg to a builtin. The two forms
# parse to different AST shapes (`ListComp` vs `GeneratorExp`) and
# pylixir should reduce both to the same Elixir reduction.

xs = [1, 2, 3, 4, 5]

# sum / max / min over a bare generator expression.
print(sum(x * x for x in xs))
print(max(x * x for x in xs))
print(min(x + 10 for x in xs))

# any / all — short-circuiting consumers.
print(any(x > 3 for x in xs))
print(all(x > 0 for x in xs))
print(any(x > 99 for x in xs))

# Filter clause inside the generator.
print(sum(x for x in xs if x % 2 == 1))

# Nested over a 2D source.
grid = [[1, 2], [3, 4], [5, 6]]
print(sum(v for row in grid for v in row))
