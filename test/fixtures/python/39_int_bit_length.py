# Regression: `(k - 1).bit_length()` raised "method .bit_length() is
# not supported". Fix: AttributeMethods routes `.bit_length()` to a
# new `py_int_bit_length/1` runtime helper. Adapted from an
# eval-corpus failure (unsupported--Call, 2026-05-16).
print((0).bit_length())
print((1).bit_length())
print((5).bit_length())
print((1023).bit_length())
print((1024).bit_length())

# The original repro: count bits needed for `k - 1`.
for k in [0, 1, 2, 5, 8, 9]:
    if k == 0:
        print(0)
    else:
        print((k - 1).bit_length())
