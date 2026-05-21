# Gap fill: 52_bitwise_set_ops covers `&|^` for ints, but `<<` and
# `>>` shift operators aren't exercised anywhere in the corpus.
# These lower to Bitwise.bsl/bsr in Elixir.

# Left shift — equivalent to multiplication by 2**n.
print(1 << 0)
print(1 << 4)
print(3 << 2)
print(255 << 1)

# Right shift — equivalent to integer division by 2**n.
print(16 >> 2)
print(255 >> 4)
print(1 >> 1)

# In expressions with other ops.
a = 5
b = 2
print((a << b) + 1)
print((a << b) | 3)
print(((a << b) & 0xff) >> 1)

# Augmented assign forms.
n = 1
n <<= 3
print(n)
n >>= 1
print(n)
