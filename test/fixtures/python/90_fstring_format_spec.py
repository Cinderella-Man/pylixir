# Regression: f-strings with format specs (`f"{h:02d}"`, `f"{x:.2f}"`)
# raised "format specs aren't supported". Fix: when the format_spec
# is a single Constant string (the common case), route through a new
# `py_format_value/2` runtime helper that interprets the spec at
# runtime (zero-pad int, fixed-precision float, alignment, etc.).
# Nested-interpolation specs (`f"{x:.{w}f}"`) still raise. Adapted
# from eval-corpus failures (unsupported--FormattedValue, 2026-05-16).

# Zero-padded ints.
for h in [0, 7, 12, 23]:
    print(f"{h:02d}")          # 00, 07, 12, 23

# Fixed-precision floats.
print(f"{3.14159:.2f}")        # 3.14
print(f"{2.71828:.4f}")        # 2.7183
print(f"{1.0:.0f}")            # 1
print(f"{0.5:.3f}")            # 0.500

# Width + precision float.
print(f"{42.0:8.2f}")          # "   42.00"

# Width int, space-padded.
print(f"{7:4d}")               # "   7"

# Alignment for strings.
print(f"{'a':>5}")             # "    a"
print(f"{'a':<5}|")            # "a    |"

# Composed format string — common pattern.
h = 14
m = 7
print(f"{h:02d}:{m:02d}")      # "14:07"

# String with default spec is identity.
print(f"{'hello':s}")          # hello
