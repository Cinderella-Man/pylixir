# Regression: `math.gcd(a, b, c, ...)` (3.9+ variadic) only supported
# the 2-arg form, raising on 3+. Added clauses for 0-arg (== 0), 1-arg
# (== abs(a)), and N-arg folding via new `py_math_gcd/1` helper.

import math

print(math.gcd())                # 0
print(math.gcd(12))              # 12
print(math.gcd(-12))             # 12
print(math.gcd(12, 18))          # 6
print(math.gcd(12, 18, 24))      # 6
print(math.gcd(100, 75, 50, 25)) # 25
print(math.gcd(7, 13, 11))       # 1
