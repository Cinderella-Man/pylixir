# Regression: `str(float)` / `repr(float)` / `print(float)` used
# BEAM's default `to_string` (or `:erlang.float_to_binary([:short])`),
# producing `"1.0e3"` for `1000.0` and `"1.0e-5"` for small floats —
# both off from Python's `repr`. Python uses fixed-point for
# `1e-4 <= abs(x) < 1e16` and scientific (`e[+-]NN`, exponent zero-
# padded) elsewhere. Added `py_str_float/1` that takes the short
# repr, parses the exponent, and either shifts the decimal point
# (for the fixed-point window) or reformats as Python sci-notation.

# Whole-number floats — should be fixed-point.
print(1000.0)
print(1e3)
print(1.5e10)
print(15000000000.0)

# Small floats with simple expansion.
print(0.001)
print(1e-3)

# Mantissa with frac.
print(1.5e2)        # 150.0
print(3.14)
print(2.5)

# Right at the scientific boundary (1e-4 / 1e16).
print(0.0001)       # 0.0001
print(1e-4)         # 0.0001 (Python boundary)
print(1e-5)         # 1e-05 (scientific)

# Large-magnitude scientific.
print(1e20)         # 1e+20
print(1.5e20)       # 1.5e+20

# Trailing zero preservation.
print(2.0)          # 2.0
print(0.0)          # 0.0

# Negative.
print(-3.14)
print(-1e-5)        # -1e-05
