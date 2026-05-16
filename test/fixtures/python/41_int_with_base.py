# Regression: `int(s, base)` raised "`int/2` is not a supported Python
# builtin call shape" — the 2-arg base-aware form was missing. Fix:
# `Pylixir.Builtins.emit("int", [x, base])` routes to Elixir's
# `String.to_integer/2`. Adapted from an eval-corpus failure
# (unsupported--Call, 2026-05-16).
print(int("101", 2))
print(int("FF", 16))
print(int("777", 8))
print(int("123", 10))

# Original repro context: bitmask parse.
for s in ["0", "1", "10", "11", "100"]:
    print(int(s, 2))
