# Regression: `math.modf` and `math.frexp` were unsupported (no clause
# in `Pylixir.Stdlib.Math.call/4`). Added clauses lowering to runtime
# helpers `py_math_modf/1` and `py_math_frexp/1` (the latter unpacks
# IEEE-754 bits to extract mantissa + exponent).

import math

# modf — (fractional, integer), both floats.
print(math.modf(3.5))             # (0.5, 3.0)
print(math.modf(-3.5))            # (-0.5, -3.0)
print(math.modf(4.0))             # (0.0, 4.0)
print(math.modf(0.25))            # (0.25, 0.0)

# frexp — (mantissa, exponent), m in [0.5, 1) or 0.
print(math.frexp(0))              # (0.0, 0)
print(math.frexp(1))              # (0.5, 1)
print(math.frexp(8))              # (0.5, 4)
print(math.frexp(0.5))            # (0.5, 0)
print(math.frexp(-3.0))           # (-0.75, 2)
