# Gap fill: `float.is_integer()` — True when the value has no
# fractional part. Common in competitive code after a division to
# test divisibility (`(a / b).is_integer()`). Adapted from an
# eval-corpus unsupported-method failure (seed_25097).
print((4.0).is_integer())   # True
print((4.5).is_integer())   # False
print((-3.0).is_integer())  # True
print((0.0).is_integer())   # True

x = 10 / 2
print(x.is_integer())       # True
y = 10 / 3
print(y.is_integer())       # False

# The corpus idiom: divide, then convert when integral.
numerator = 12
denominator = 4
i_val = numerator / denominator
if i_val.is_integer():
    i_val = int(i_val)
print(i_val)                # 3
