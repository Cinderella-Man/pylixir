# Regression: `print(*xs, sep=",")` ignored the `sep=` kwarg — the
# star-unpack lowering (`emit_starred_call("print", ...)`) didn't
# even read the call's kwargs. Same for `end=`. Routed both kwargs
# through to `py_print_iter/3` (was /1) with Python's defaults.

xs = [1, 2, 3]
print(*xs, sep=",")                  # 1,2,3
print(*xs, sep=" | ")                # 1 | 2 | 3
print(*xs, end="!")                  # 1 2 3!
print()                              # newline after the previous

# sep + end together.
print(*xs, sep=";", end=".\n")       # 1;2;3.

# Unpacked string — each grapheme separately.
print(*"abc", sep="-")               # a-b-c

# Empty unpack + custom end.
print(*[], end="<end>\n")            # <end>
