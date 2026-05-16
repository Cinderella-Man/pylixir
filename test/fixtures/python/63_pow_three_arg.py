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

# 2-arg pow still works.
print(pow(2, 10))
print(pow(3, 4))
