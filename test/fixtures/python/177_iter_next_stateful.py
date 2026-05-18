# Regression: `iter()` / `next()` raised `iterator protocol is not
# supported`, blocking the classic stateful-iter idiom for
# subsequence checks. Backed by a process-dict-keyed cursor: each
# `iter(x)` allocates a unique handle; `c in it` and `next(it)` both
# pop the head element after a match. Adapted from synthetic_sft
# sample 1131 (2026-05-18).
def is_subsequence(sub, main):
    it = iter(main)
    return all(c in it for c in sub)


print(is_subsequence("ace", "abcde"))      # True
print(is_subsequence("aec", "abcde"))      # False (order matters)
print(is_subsequence("", "abc"))           # True
print(is_subsequence("abc", "ab"))         # False (run out of main)

# Bare next(it) / next(it, default).
it = iter([10, 20, 30])
print(next(it))                            # 10
print(next(it))                            # 20
print(next(it))                            # 30
print(next(it, -1))                        # -1 (exhausted, default kicks in)

# Iter over a string — graphemes.
ci = iter("xyz")
print(next(ci))                            # x
print(next(ci))                            # y
