# Regression: `@lru_cache` (and `@functools.lru_cache(maxsize=None)`,
# `@cache`) on both top-level and nested function defs raised
# "decorators are not supported". Fix: a `safe_to_strip_decorator?/1`
# predicate identifies memoization decorators we can drop without
# changing correctness (only performance), and `from functools import
# lru_cache` plus `import functools` are no-op imports. The function
# itself works correctly via plain re-computation. Adapted from
# eval-corpus failures (unsupported--FunctionDef, 2026-05-16).
import functools
from functools import lru_cache, cache

# Top-level def with bare `@lru_cache`.
@lru_cache
def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

print(fib(10))   # 55
print(fib(15))   # 610

# Top-level def with `@lru_cache(maxsize=None)` (called decorator form).
@lru_cache(maxsize=None)
def max_currency(n):
    if n == 0:
        return 0
    return max(n, max_currency(n // 2) + max_currency(n // 3))

print(max_currency(12))    # 13

# Nested def with `@cache` (3.9+ shorthand).
def main():
    @cache
    def squared(x):
        return x * x
    return squared(3) + squared(4) + squared(5)

print(main())              # 9 + 16 + 25 = 50

# Fully-qualified `@functools.lru_cache(...)` also strips.
@functools.lru_cache(maxsize=128)
def triple(x):
    return x * 3

print(triple(7))           # 21
