# Regression: `set_a & set_b` raised a Bitwise.band/2 type error at
# Elixir compile time — Pylixir lowered Python's `&`/`|`/`^` to
# `Bitwise.band` etc. regardless of operand type, but Python overloads
# them for set intersection / union / symmetric-difference.
# Fix: new `py_band` / `py_bor` / `py_bxor` runtime helpers dispatch
# on `MapSet` first, falling through to `Bitwise.*` for ints. Adapted
# from an eval-corpus failure
# (compile_error--incompatible_types_given_to_Bitwise.band_2_, 2026-05-16).

# Set ops via the operator shorthand.
a = set([1, 2, 3, 4])
b = set([3, 4, 5, 6])
print(sorted(a & b))
print(sorted(a | b))
print(sorted(a ^ b))

# Same operators on ints still do bitwise.
print(0b1100 & 0b1010)
print(0b1100 | 0b1010)
print(0b1100 ^ 0b1010)
