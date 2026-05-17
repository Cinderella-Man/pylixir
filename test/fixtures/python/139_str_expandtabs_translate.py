# Regression: `str.expandtabs`, `str.maketrans`, and `str.translate`
# weren't dispatched. Added runtime helpers `py_str_expandtabs/2`,
# `py_str_maketrans/2`, `py_str_translate/2`. expandtabs replaces
# tabs with enough spaces to reach the next tab-stop (column-aware,
# resets at newline). translate replaces graphemes via the mapping
# table (accepts both grapheme-keyed maps from `str.maketrans` and
# Python's ord-int-keyed maps).

# expandtabs default (tabsize=8).
print("a\tb")                           # a       b (a + 7 spaces + b)
print("ab\tc")                          # ab      c (ab + 6 spaces + c)
print("abcd\tef")                       # abcd    ef (4 spaces)

# Custom tabsize.
print("a\tb\tc".expandtabs(4))          # a   b   c

# Tab at col 0.
print("\tx".expandtabs(4))              # 4 spaces + x

# Multi-line — column resets at newline.
print("a\tb\nc\td".expandtabs(4))

# maketrans + translate — character substitution.
table = str.maketrans("abc", "xyz")
print("aabcd".translate(table))         # xxyzd

# Identity / no-match.
print("xyz".translate(table))           # xyz (no a/b/c)

# Empty maketrans roundtrip — also no change.
empty = str.maketrans("", "")
print("hello".translate(empty))         # hello

# Common idiom: rot13-ish swap of two chars.
swap = str.maketrans("ab", "ba")
print("abab".translate(swap))           # baba
