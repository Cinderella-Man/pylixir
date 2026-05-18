# Regression: `bytearray([...])` raised `bytearray is not supported`,
# blocking the sieve-of-Eratosthenes idiom common in competitive
# code. Backing rep is now a list of uint8 ints (same as Pylixir's
# `bytearray(iter)` lowering); bytes literals with binary content
# (NUL bytes, undecodable sequences) also serialise as list-of-ints
# so slice-assign + subscript-read work uniformly. UTF-8-text bytes
# literals still decode to plain strings (fixture 110 covers that).
# Adapted from synthetic_sft sample 1004 (2026-05-18).
n_max = 30
sieve = bytearray([1]) * (n_max + 1)
sieve[0] = 0
sieve[1] = 0
for i in range(2, int(n_max ** 0.5) + 1):
    if sieve[i]:
        sieve[i * i :: i] = b"\x00" * ((n_max - i * i) // i + 1)

primes = [i for i in range(n_max + 1) if sieve[i]]
print(primes)
# [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
