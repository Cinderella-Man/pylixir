# Regression: Python's 3-arg `pow(base, exp, mod)` (modular
# exponentiation) was emitted as bare `pow/3`, which doesn't exist
# in Kernel and broke compilation. Fix: route `pow(b, e, m)` through
# a new `py_pow_mod/3` runtime helper backed by :crypto.mod_pow.
# Common in competitive code for Fermat's-little-theorem modular
# inverses (`pow(x, MOD-2, MOD)`). 2-arg `pow(b, e)` still routes
# through `py_pow`. Adapted from an eval-corpus failure
# (compile_quoted_raised, 2026-05-16).
MOD = 998244353

# Fermat's little theorem: modular inverse of x mod prime p is x^(p-2) mod p.
inv = pow(5, MOD - 2, MOD)
print((inv * 5) % MOD)  # 1

# Small concrete checks.
print(pow(2, 10, 1000))  # 1024 mod 1000 = 24
print(pow(3, 7, 100))    # 2187 mod 100 = 87
print(pow(7, 0, 13))     # 1

# Negative base: Python reduces the base modulo `mod` first, so the
# result lands in [0, mod). :crypto.mod_pow mishandles a raw negative
# base, so py_pow_mod must normalise it.
print(pow(-1, 3, MOD))   # 998244352
print(pow(-1, 4, MOD))   # 1
print(pow(-5, 3, 100))   # -125 mod 100 = 75

# Negative exponent (Python 3.8+): `pow(a, -1, m)` is the modular inverse
# of `a` mod `m`, and `pow(a, -k, m)` is that inverse raised to the k-th
# power mod `m`. Requires `a` invertible mod `m` (gcd == 1).
print(pow(3, -1, 7))     # 5  (3*5 == 15 ≡ 1 mod 7)
print(pow(10, -1, 17))   # 12
print(pow(2, -3, 7))     # 1  (inverse(2,7)=4; 4**3 == 64 ≡ 1 mod 7)
print(pow(5, -1, MOD))   # modular inverse of 5 mod the big prime

# 2-arg pow still works.
print(pow(2, 10))
print(pow(3, 4))
