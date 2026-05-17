# Regression: the builtin `repr(x)` was emitted as a bare `repr(...)`
# call (no such function in the generated module), causing CompileError.
# `py_repr/1` already existed for the f-string `!r` conversion flag
# and the internal repr_list/tuple/map helpers; just wired the builtin
# `repr` to call it.

# String repr keeps quotes.
print(repr("hello"))                 # 'hello'
print(repr(""))                       # ''

# Number repr.
print(repr(42))                       # 42
print(repr(3.14))                     # 3.14

# Container repr.
print(repr([1, 2, 3]))               # [1, 2, 3]
print(repr((1, "a")))                # (1, 'a')

# None / bool.
print(repr(None))                    # None
print(repr(True))                    # True

# Use in f-string.
x = "world"
print(f"x is {x!r}")                 # x is 'world'
print(f"x is {repr(x)}")             # x is 'world'
