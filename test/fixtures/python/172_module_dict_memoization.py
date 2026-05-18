# Regression: module-level `memo = {}` mutated via `memo[k] = v`
# inside a top-level def was rejected as unsupported--Module because
# Pylixir lowers module-level literals to immutable Elixir module
# attributes. Now lowered through the Erlang Process dict so the
# mutation persists across calls. Adapted from synthetic_sft samples
# 1695/1697/1752 (2026-05-18).

memo = {1: 1}

def max_chain(x):
    if x in memo:
        return memo[x]
    # Sum of proper divisors of x (excluding x itself).
    s = 0
    i = 1
    while i * i <= x:
        if x % i == 0:
            s += i
            if i != 1 and i != x // i:
                s += x // i
        i += 1
    best = 0
    if s < x and s >= 1:
        cand = max_chain(s)
        if cand > best:
            best = cand
    memo[x] = x + best
    return memo[x]

print(max_chain(1))    # 1
print(max_chain(6))    # 6 + max_chain(6) where divisors(6)\{6}=1+2+3=6 → cycles; just check shape
print(max_chain(12))   # 12 + max_chain(16) where divisors(12)\{12}=1+2+3+4+6=16

# Second call hits the cached value — the mutation persisted.
print(max_chain(12))   # same as above

# Empty memo (overwrite at module level).
counts = {}

def bump(k):
    counts[k] = counts.get(k, 0) + 1

bump("a")
bump("a")
bump("b")
print(counts["a"])  # 2
print(counts["b"])  # 1
