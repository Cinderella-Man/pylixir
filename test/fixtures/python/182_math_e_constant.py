# Regression: `math.e` was emitted as `:math.e()`, but Erlang's
# `:math` module has no `e/0` BIF (only `pi/0`). The result was a
# silent compile_error--_math.e_0_is_undefined: `Pylixir.transpile`
# returned :ok and `Code.compile_quoted/1` blew up later with
# "function :math.e/0 is undefined or private. Did you mean:
# erf/1, exp/1". Fix: emit the IEEE-754 double Euler's constant
# (2.718281828459045) as a literal float — matches CPython's
# `math.e` byte-for-byte and avoids the spurious `:math.exp(1)`
# runtime call.

import math

print(math.e)  # 2.718281828459045
print(round(math.e * 1000) / 1000)  # 2.718
print(round(math.e ** 2, 6))  # 7.389056
