# Regression: `import re` raised "no stdlib translation". Fix:
# registered `Pylixir.Stdlib.Re` that routes `re.findall / search /
# match / sub / split` through runtime helpers backed by Elixir's
# `Regex` module. Patterns are compiled at runtime via
# `Regex.compile!/1` — Python regex syntax is PCRE-compatible enough
# for the common competitive-programming patterns. Adapted from an
# eval-corpus failure (unsupported--Import, 2026-05-16).
import re

# findall — list of all matches.
text = "abc123 def456 ghi789"
print(re.findall(r"[a-z]+", text))     # ['abc', 'def', 'ghi']
print(re.findall(r"\d+", text))        # ['123', '456', '789']

# Empty result.
print(re.findall(r"xyz", text))        # []

# search / match return Match objects in Python; Pylixir simplifies
# to "matched string or None" — print existence rather than the
# object repr.
print(re.search(r"\d+", text) is not None)   # True
print(re.search(r"xyz", text) is None)       # True
print(re.match(r"abc", text) is not None)    # True (anchored at start)
print(re.match(r"def", text) is None)        # True (def isn't at start)

# sub — replace all occurrences.
print(re.sub(r"\d+", "#", text))       # 'abc# def# ghi#'

# split — break on the pattern.
print(re.split(r"\s+", "  one two   three "))   # ['', 'one', 'two', 'three', '']

# Realistic case: extract email-like tokens.
log = "user@host:42 admin@host:1 guest@host:7"
print(re.findall(r"\w+@\w+:\d+", log))
