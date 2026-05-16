# Regression: `math.gcd` raised "not a supported stdlib call". Fix:
# `Pylixir.Stdlib.Math` now translates `math.gcd(a, b)` to Elixir's
# `Integer.gcd/2`. Adapted from an eval-corpus failure
# (unsupported--Call, 2026-05-16).
import math

print(math.gcd(12, 8))
print(math.gcd(100, 75))
print(math.gcd(0, 5))

# Iterative reduce — common in number-theory snippets.
current = 24
for r in [36, 60, 18]:
    current = math.gcd(current, r)
print(current)
