# Regression: Python's `'fmt' % args` string formatting raised
# ArgumentError with a "use string concatenation" hint, blocking any
# eval sample using the classic %-style. Added a runtime formatter
# (`py_str_percent_format/3` + parsers) covering the common spec
# subset: %d/%i, %s, %f (with .N precision), %e, %x/%X, %o, %b, %c,
# %%, plus the `-` left-align, `0` zero-pad, `+` always-sign, ` `
# space-sign flags and width.

# Tuple-arg form.
print("%d + %d = %d" % (2, 3, 5))           # 2 + 3 = 5
print("%s = %d" % ("answer", 42))           # answer = 42

# Single-value (non-tuple) form.
print("hi %s" % "there")                    # hi there
print("%d" % 100)                           # 100

# Width + zero-pad.
print("%05d" % 42)                          # 00042
print("%5d" % 42)                           # "   42"
print("%-5d|" % 42)                         # "42   |"

# Float precision.
print("%.2f" % 3.14159)                     # 3.14
print("%10.2f" % 3.14)                      # "      3.14"
print("%-10.2f|" % 3.14)                    # "3.14      |"

# Hex / oct (Python's `%` formatting has no `%b`; use bin() or
# format() for binary).
print("%x" % 255)                           # ff
print("%X" % 255)                           # FF
print("%o" % 8)                             # 10

# Always-sign / space-sign.
print("%+d" % 5)                            # +5
print("%+d" % -5)                           # -5
print("% d" % 5)                            # " 5"

# Literal %.
print("%d%%" % 99)                          # 99%

# Negative zero-pad keeps sign on the left.
print("%05d" % -42)                         # -0042

# %s on non-string.
print("%s" % [1, 2, 3])                     # [1, 2, 3]
print("%s" % 3.14)                          # 3.14

# Multiple in one format.
print("[%s] %3d/%3d (%5.1f%%)" % ("done", 7, 12, 58.3333))
# Python: [done]   7/ 12 ( 58.3%)
