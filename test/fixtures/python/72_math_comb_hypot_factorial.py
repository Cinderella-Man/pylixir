# Regression: `math.comb(n, k)`, `math.hypot(*coords)`,
# `math.factorial(n)`, and `math.log(x, base)` raised "not a
# supported stdlib call". Fix: registered all four in
# `Pylixir.Stdlib.Math` and added `py_math_comb`, `py_math_factorial`,
# `py_math_hypot` runtime helpers. `comb` uses the multiplicative
# formula so it scales without ballooning factorials. Adapted from
# eval-corpus failures (unsupported--Call, 2026-05-16).
import math

# Binomial coefficients (math.comb).
print(math.comb(10, 3))    # 120
print(math.comb(5, 0))     # 1
print(math.comb(5, 5))     # 1
print(math.comb(0, 0))     # 1
print(math.comb(3, 5))     # 0 (k > n → 0)

# Variadic Euclidean norm (math.hypot, Python 3.8+).
print(math.hypot(3.0, 4.0))                  # 5.0
print(round(math.hypot(1.0, 2.0, 2.0), 5))   # 3.0

# Factorial.
print(math.factorial(0))   # 1
print(math.factorial(1))   # 1
print(math.factorial(5))   # 120
print(math.factorial(10))  # 3628800

# Explicit-base log.
print(math.log(100, 10))   # 2.0
print(round(math.log(8, 2), 5))    # 3.0
