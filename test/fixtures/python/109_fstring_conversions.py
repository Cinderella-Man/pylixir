# Regression: f-string conversion flags `!r`, `!s`, `!a` were ignored
# (the AST has a `conversion` field of 114/115/97, previously
# dropped). Fix: applied via a new `apply_conversion/2` helper that
# wraps the value in `py_repr` or `py_str` before format-spec handling.
# `!r` and `!a` both route to `py_repr` (Pylixir doesn't model the
# ASCII-only escape distinction). Adapted from common Python idioms.

# !r — repr (strings get quotes).
print(f"{'hello'!r}")            # 'hello'
print(f"{42!r}")                  # 42

# !s — same as default, but explicit.
print(f"{42!s}")                  # 42
print(f"{[1, 2, 3]!s}")          # [1, 2, 3]

# !a — Pylixir collapses to !r since we don't model ASCII escaping.
print(f"{'abc'!a}")               # 'abc'

# Combine !r with a format spec.
print(f"{'hi'!r:>8}")             # "    'hi'"
