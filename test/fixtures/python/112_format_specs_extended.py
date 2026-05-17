# Regression: f-string and .format format specs for binary/hex/octal
# (`{:b}`, `{:08b}`, `{:x}`, `{:X}`, `{:o}`), signed int (`{:+d}`),
# and thousands separator (`{:,}`) all fell to the py_str fallback
# (just emitted the value). Fix: extended `parse_format_spec` with
# regex clauses for each, and added new helper branches in
# `py_format_value/2` plus an `insert_thousands_separators/2` helper.

# Binary.
print(f"{42:b}")                # 101010
print(f"{42:08b}")              # 00101010
print(f"{5:04b}")               # 0101

# Hex.
print(f"{255:x}")               # ff
print(f"{255:X}")               # FF
print(f"{255:04x}")             # 00ff

# Octal.
print(f"{8:o}")                 # 10
print(f"{64:o}")                # 100

# Signed int.
print(f"{5:+d}")                # +5
print(f"{-5:+d}")               # -5
print(f"{42:+}")                # +42

# Thousands separator.
print("{:,}".format(1234567))   # 1,234,567
print("{:,}".format(-1000000))  # -1,000,000
print("{:,}".format(999))       # 999
