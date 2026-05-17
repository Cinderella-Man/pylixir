# Regression: `print({42})` crashed with
# `Protocol.UndefinedError: String.Chars not implemented for MapSet`.
# `py_str/1` had no MapSet clause — the dispatch fell through to
# `to_string/1` which raised. Added `py_str(%MapSet{})` →
# `py_repr_set/1` that prints Python's set repr: `{1, 2, 3}` or
# `set()` for empty (since `{}` is dict-literal syntax).
#
# MapSet has no insertion-order guarantee, so multi-element prints
# would have non-deterministic order vs Python — fixture sticks to
# single-element and empty cases plus order-independent checks.

print({42})                         # {42}
print({"only"})                      # {'only'}
print(set())                         # set()

# Membership unaffected by repr.
s = {1, 2, 3}
print(2 in s)                        # True
print(99 in s)                       # False
print(len(s))                        # 3

# sorted() yields deterministic output for multi-element cases.
print(sorted({3, 1, 2}))             # [1, 2, 3]
