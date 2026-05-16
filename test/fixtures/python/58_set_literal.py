# Regression: `{1, 2, 3}` set literals raised `UnsupportedNodeError("Set")`.
# Fix: `convert(%{"_type" => "Set", ...})` lowers to `MapSet.new([…])`.
# Note that `{}` is a *dict* literal in Python (not an empty set), so
# Pylixir's Dict clause handles that case; the Set clause always has
# at least one element. Adapted from an eval-corpus failure
# (unsupported--Set, 2026-05-16).

s = {1, 2, 3, 4, 5}
print(sorted(s))
print(3 in s)
print(99 in s)

# Set ops via operators.
a = {1, 2, 3}
b = {3, 4, 5}
print(sorted(a & b))
print(sorted(a | b))

# Set literal as a function arg.
def has_vowel(c):
    return c in {"a", "e", "i", "o", "u"}

print(has_vowel("e"))
print(has_vowel("x"))
