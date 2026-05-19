# Regression: `math.gcd` is supported as a Call (via
# `Pylixir.Stdlib.Math.call(["gcd"], …)`), but reading it as an
# *attribute* — `f = math.gcd`, `reduce(math.gcd, xs)`,
# `sorted(xs, key=...)` etc. — produced
# unsupported--Attribute("`math.gcd` is not a supported stdlib
# attribute"). Fix: a new `attribute(["gcd"], _)` clause that emits
# `&Integer.gcd/2`. Python's gcd is variadic in 3.9+, but every
# realistic use as a value (reduce, max-key) calls it with two args.

import math

f = math.gcd
print(f(12, 8))  # 4
print(f(15, 25))  # 5
print(f(7, 13))  # 1 (coprime)
