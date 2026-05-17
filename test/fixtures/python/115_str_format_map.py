# Regression: `str.format_map(mapping)` was unsupported. Unlike
# `.format(**kwargs)` it takes a runtime mapping, so compile-time
# template resolution doesn't apply — added `py_str_format_map/2`
# runtime helper that parses the template + substitutes named
# placeholders. Format specs supported via shared `py_format_value/2`.

# Basic named substitution.
print("Hello, {name}!".format_map({"name": "Alice"}))  # Hello, Alice!

# Multiple placeholders.
d = {"first": "Ada", "last": "Lovelace"}
print("{first} {last}".format_map(d))                   # Ada Lovelace

# Format spec carries through.
stats = {"score": 95.5, "rank": 3}
print("{score:.1f} (rank {rank:02d})".format_map(stats))  # 95.5 (rank 03)

# Literal braces via `{{` / `}}`.
print("{{{name}}}".format_map({"name": "X"}))           # {X}
