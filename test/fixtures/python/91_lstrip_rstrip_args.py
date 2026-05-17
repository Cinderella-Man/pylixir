# Regression: `line.rstrip('\n')` (and `lstrip(chars)`) raised
# "method `.rstrip()` is not supported" — the 0-arg form was
# already routed to `String.trim_trailing/1`, but the 1-arg form
# wasn't. Fix: added `lstrip(chars)` and `rstrip(chars)` clauses
# that delegate to `String.trim_leading/2` / `String.trim_trailing/2`,
# mirroring the existing `strip(chars)` handling (and reusing
# `reject_multichar_strip!/2` since Elixir trims pattern-by-pattern
# rather than as a char set). Adapted from an eval-corpus failure
# (unsupported--Call, 2026-05-16).
print("hello\n".rstrip("\n"))      # "hello"
print("xxxhellox".rstrip("x"))     # "xxxhello"
print("xxxhello".lstrip("x"))      # "hello"

# Common pattern: stripping trailing newlines off a stdin line.
line = "data\n"
stripped = line.rstrip("\n")
print(stripped)
print(len(stripped))               # 4

# 0-arg form still works.
print("  hi  ".strip())            # "hi"
print("aabbaa".lstrip())           # "aabbaa" (only whitespace)
