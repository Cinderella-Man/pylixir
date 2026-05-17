# Regression: `float("inf")` clamps to `1.0e308` (BEAM has no IEEE
# infinity), and `print(...)` then emitted `1e+308` — way off from
# Python's `inf`. Fix: special-case the exact clamp values in
# `py_str_float/1` to print `inf`/`-inf`. False-positive risk (real
# `1.0e308` computation result) is theoretical.

print(float("inf"))                  # inf
print(float("-inf"))                 # -inf
print(float("infinity"))             # inf
print(float("INF"))                  # inf

# In an f-string.
x = float("inf")
print(f"value: {x}")                 # value: inf

# Equality + ordering work fine on the clamp value.
print(float("inf") > 1e10)           # True
print(float("-inf") < -1e10)         # True
print(float("inf") > float("-inf"))  # True
