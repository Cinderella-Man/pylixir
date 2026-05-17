# Regression: `frozenset()` and `frozenset(iter)` weren't lowered and
# appeared as bare `frozenset(...)` calls in the generated Elixir,
# causing CompileError. Elixir's MapSet already provides immutable
# value semantics — frozenset routes to the same shape as `set(...)`.

# Empty frozenset.
fs = frozenset()
print(len(fs))                       # 0

# From a list.
fs = frozenset([1, 2, 3, 2, 1])
print(sorted(fs))                    # [1, 2, 3]

# From a tuple.
fs = frozenset((4, 5, 6))
print(sorted(fs))                    # [4, 5, 6]

# Membership and intersection — the common eval-sample usage.
a = frozenset({1, 2})
b = frozenset({2, 3})
print(1 in a)                        # True
print(sorted(a & b))                 # [2]
print(sorted(a | b))                 # [1, 2, 3]

# frozenset in a dedup set — the actual idiom from sample 003.
seen = set()
seen.add(frozenset({1, 2}))
seen.add(frozenset({2, 1}))          # same set; dedup
seen.add(frozenset({3, 4}))
print(len(seen))                     # 2
