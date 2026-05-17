# Regression: `str.removeprefix(p)` / `str.removesuffix(s)` (Python
# 3.9+) raised "method `.X()` is not supported". Fix: added clauses
# routing to `py_str_remove_prefix/2` and `py_str_remove_suffix/2`
# (strip exactly one occurrence if matched, else return unchanged —
# NOT the same as lstrip/rstrip which strip a set repeatedly).

# Common idiom — stripping a known prefix from a filename / path.
print("test_foo".removeprefix("test_"))    # foo
print("foo".removeprefix("test_"))         # foo (no match → unchanged)
print("file.txt".removesuffix(".txt"))     # file
print("file".removesuffix(".txt"))         # file

# Difference from lstrip: lstrip treats arg as a SET of chars to
# strip repeatedly. removeprefix is a single-shot exact match. The
# multi-char lstrip form is rejected in Pylixir (L4 will fix it),
# so only the removeprefix non-match case is exercised here.
print("teest_xxx".removeprefix("test_"))   # teest_xxx (no exact match)

# Empty prefix/suffix is a no-op.
print("hello".removeprefix(""))            # hello
print("hello".removesuffix(""))            # hello

# Exact match leaves empty string.
print("abc".removeprefix("abc"))           # (empty)
print("abc".removesuffix("abc"))           # (empty)
