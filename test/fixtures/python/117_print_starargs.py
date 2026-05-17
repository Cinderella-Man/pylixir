# Regression: `print(*xs)` (unpack-print) raised UnsupportedNodeError
# from `emit_starred_call/3` because no clause handled the `print`
# builtin. Added a `print` branch routing to `py_print_iter/1` (which
# py_str's each elem + space-joins + newline-terminates — matching
# default `print()`).

xs = [1, 2, 3]
print(*xs)                          # 1 2 3

# Tuple unpacked.
t = ("a", "b", "c")
print(*t)                           # a b c

# Empty iter — bare newline (matches Python's `print()` no-arg).
print(*[])                          # (blank line)

# Mixed types coerce via py_str.
print(*[1, 2.5, "x", True])         # 1 2.5 x True

# Star-unpack a range.
print(*range(5))                    # 0 1 2 3 4
