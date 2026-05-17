"""Module-level docstring — extracted (not just stripped) and emitted
as Elixir's `@moduledoc`. Only treated as a docstring when followed
by other statements (a one-statement string module is the program's
return value, not a docstring).

Function-level docstrings are promoted to `@doc` on the top-level
`def`. Closures and lambdas don't have an Elixir-side equivalent
and still get stripped.

Adapted from eval-corpus failures (compile_error--unused_literal,
2026-05-16)."""

def sieve(n):
    """Generate a sieve of Eratosthenes up to n."""
    if n < 2:
        return []
    s = [True] * (n + 1)
    s[0] = s[1] = False
    for i in range(2, int(n ** 0.5) + 1):
        if s[i]:
            for j in range(i * i, n + 1, i):
                s[j] = False
    return [i for i, p in enumerate(s) if p]


def check_region(grid, r, c):
    """Check if a given region is full (no empty cells)."""
    return all(cell != "." for cell in grid[r:c])


print(sieve(20))
print(check_region([["a", "b", "c"]], 0, 1))
