# Regression: `str.splitlines()` raised "method `.splitlines()` is
# not supported". Fix: added to attribute_methods' @string_methods and
# `py_str_splitlines/1` runtime helper. Semantics match Python: split
# on \r\n / \r / \n; trailing line terminator doesn't produce an
# empty final entry. Adapted from an eval-corpus failure
# (unsupported--Call, 2026-05-16).
text = "alpha\nbeta\ngamma"
for line in text.splitlines():
    print(line)

print("---")

# Trailing newline doesn't produce a trailing empty.
print(len("alpha\nbeta\n".splitlines()))  # 2

# Mixed line endings.
print("a\r\nb\rc\nd".splitlines())

# Empty string.
print("".splitlines())
