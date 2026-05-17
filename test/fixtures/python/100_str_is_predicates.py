# Regression: `.islower()`, `.isupper()`, `.isspace()`, `.isdecimal()`,
# `.isnumeric()`, `.isascii()` raised "method `.X()` is not supported".
# Fix: added regex-backed clauses for isspace/isdecimal/isnumeric/isascii
# and runtime helpers for islower/isupper (which need the "at least one
# cased char" check beyond a simple regex match).
print("hello".islower())          # True
print("Hello".islower())          # False
print("".islower())               # False
print("123".islower())            # False (no cased chars)

print("HELLO".isupper())          # True
print("Hello".isupper())          # False
print("".isupper())               # False
print("123 ABC".isupper())        # True

print("  \t\n".isspace())         # True
print(" hi ".isspace())           # False
print("".isspace())               # False

print("1234".isdecimal())         # True
print("12.3".isdecimal())         # False
print("".isdecimal())             # False

print("abc".isascii())            # True
print("".isascii())               # True
print("café".isascii())           # False
