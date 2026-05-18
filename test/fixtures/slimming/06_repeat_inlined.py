# Targets S5: `itertools.repeat` calls inline to `List.duplicate/2`
# directly; no `defp repeat` wrapper in the output.

from itertools import repeat

xs = list(repeat(0, 5))
print(xs)

ys = list(repeat("hi", 3))
print(ys)
