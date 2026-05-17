# Regression: `s.endswith((".py", ".pyc"))` (tuple of suffixes — the
# Python idiom for "any of these") crashed with
# `FunctionClauseError: no function clause matching in
# String.ends_with?/2`. Elixir's `String.starts_with?/2` and
# `String.ends_with?/2` accept a string OR a LIST, but not a tuple.
# Fix: route through `py_str_startswith/2` and `py_str_endswith/2`
# runtime helpers that convert tuples to lists, passing single
# strings through unchanged.

# Tuple of suffixes — the bug trigger.
print("foo.py".endswith((".py", ".pyc")))             # True
print("foo.txt".endswith((".py", ".pyc")))            # False
print("foo.pyc".endswith((".py", ".pyc")))            # True

# Tuple of prefixes.
print("https://x".startswith(("http://", "https://"))) # True
print("ftp://x".startswith(("http://", "https://")))   # False

# Single-string forms (unchanged path).
print("hello".endswith("lo"))                          # True
print("hello".startswith("he"))                        # True
print("hello".endswith("nope"))                        # False

# Common idiom: file-extension check.
files = ["a.py", "b.js", "c.pyc", "d.txt"]
print([f for f in files if f.endswith((".py", ".pyc"))])  # ['a.py', 'c.pyc']
