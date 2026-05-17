# Regression: `s.strip("abc")` (multi-char arg) raised "Python strips
# ANY of those chars from ends; Elixir's String.trim/2 strips exactly
# that string". Fix: route the 1-arg `.strip/.lstrip/.rstrip` forms
# through new runtime helpers (`py_str_strip_chars` family) that
# iterate grapheme-by-grapheme treating the arg as a SET of chars.
# Single-char `.strip("x")` still works (single char IS a 1-element
# set). Adapted from a pre-existing rejection that was overdue.

# Multi-char strip from both ends.
print("xxxhelloxxx".strip("x"))      # hello
print("abcdefabc".strip("abc"))      # def

# lstrip — strip from left only.
print("aabbccdd".lstrip("abc"))      # dd
print("test_xxx".lstrip("test_"))    # xxx  (any of t,e,s,_)
print("xxx".lstrip("abc"))           # xxx  (nothing to strip)

# rstrip — strip from right only.
print("aabbccdd".rstrip("cd"))       # aabb
print("file.txt".rstrip(".txt"))     # file (any of .,t,x — strips back to 'file')

# Combined: only ends are stripped; interior chars left.
print("aaaXXXbbbXXXccc".strip("abc")) # XXXbbbXXX

# Empty set — nothing strips.
print("hello".strip(""))             # hello
