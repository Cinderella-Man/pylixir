# Regression: `math.isqrt(n)` raised "not a supported stdlib call".
# Fix: `Pylixir.Stdlib.Math` translates to `trunc(:math.sqrt(n))` —
# observationally exact for n up to about 2^53. Adapted from an
# eval-corpus failure (unsupported--Call, 2026-05-16).
import math

print(math.isqrt(0))
print(math.isqrt(1))
print(math.isqrt(4))
print(math.isqrt(10))
print(math.isqrt(100))
print(math.isqrt(99))

# Original repro context: factor-finding loop bound.
p = 50
for i in range(1, int(math.isqrt(p)) + 1):
    if p % i == 0:
        print(i)
