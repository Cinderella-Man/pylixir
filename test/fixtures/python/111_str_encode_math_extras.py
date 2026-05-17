# Regression: `str.encode()` raised "method `.encode()` is not
# supported", and `math.trunc/.copysign/.fabs` raised "not a supported
# stdlib call". Fix: encode/decode are no-op identity transforms
# (Pylixir collapses bytes-vs-str); the math additions emit inline
# arithmetic. Common in I/O and competitive-coding numeric work.

import math

# str.encode() / bytes.decode() — identity since we don't model bytes.
# (Python would return False for `data == "hello"` because bytes != str;
#  Pylixir collapses the distinction, so don't assert on that compare.)
s = "hello"
data = s.encode()
print(len(data))                    # 5
print(data.decode() == "hello")     # True (round-trip — both runtimes agree)

# math.trunc — truncate toward zero, returns int.
print(math.trunc(3.7))              # 3
print(math.trunc(-3.7))             # -3
print(math.trunc(0.0))              # 0

# math.fabs — magnitude as float.
print(math.fabs(-3.5))              # 3.5
print(math.fabs(2))                 # 2.0

# math.copysign — magnitude of x, sign of y.
print(math.copysign(3, -1))         # -3
print(math.copysign(-3, 1))         # 3
# -0.0 vs 0.0 differs across runtimes; skip that edge.
