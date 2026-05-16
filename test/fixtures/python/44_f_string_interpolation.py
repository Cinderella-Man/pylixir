# Regression: f-strings (`f"x={x}"`) raised `UnsupportedNodeError("JoinedStr")`.
# Fix: `Pylixir.Converter` lowers `JoinedStr` to a chain of `<>`
# concats with each `FormattedValue` wrapped in `py_str`. Format specs
# (`f"{x:.2f}"`) still raise with a hint pointing at the
# `"{:.2f}".format(x)` workaround. Adapted from an eval-corpus
# failure (unsupported--JoinedStr, 2026-05-16).
home = 5
away = 3
print(f"{home} {away}")
print(f"score: {home}-{away}")

# Single-interpolation forms.
n = 10
print(f"n is {n}")

# Multi-line / many-parts shape.
a, b, c = 1, 2, 3
print(f"a={a} b={b} c={c}")

# Plain string (no interpolation) — f-prefix is technically a JoinedStr
# with one Constant child in CPython 3.14.
print(f"plain")
