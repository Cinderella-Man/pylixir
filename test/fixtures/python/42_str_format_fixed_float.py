# Regression: `"{0:.6f}".format(value)` raised "method `.format()` is
# not supported". Fix: `Pylixir.Nodes.AttributeMethods` parses the
# common single-placeholder forms — `{}` / `{N}` (bare positional) and
# `{:.Nf}` / `{N:.Nf}` (float with N decimals) — at codegen time.
# Other format shapes still raise with a clearer hint pointing at
# what *is* supported. Adapted from an eval-corpus failure
# (unsupported--Call, 2026-05-16).

# Float with N decimals (the eval-corpus shape — `{0:.6f}` / `{0:.9f}`).
print("{0:.6f}".format(3.14159265358979))
print("{:.2f}".format(7))         # int coerced to float, padded
print("{0:.3f}".format(0.1))
print("{0:.9f}".format(1.0 / 3))  # the other eval-corpus shape

# Bare positional, indexed and un-indexed.
print("{}".format(42))
print("{0}".format("hello"))
