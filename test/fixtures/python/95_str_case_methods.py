# Regression: `str.title()`, `str.capitalize()`, `str.swapcase()`,
# `str.casefold()` raised "method `.X()` is not supported". Fix:
# added to attribute_methods' @string_methods + 3 new runtime helpers
# (`py_str_title`, `py_str_capitalize`, `py_str_swapcase`); casefold
# delegates to `String.downcase/1`. Adapted from common Python idioms.

# title — first letter of every alpha-run, rest lowercase.
print("hello world".title())                # Hello World
print("HELLO WORLD".title())                # Hello World
print("one-two-three".title())              # One-Two-Three
print("123abc456def".title())               # 123Abc456Def

# capitalize — first char upper, rest lower.
print("hELLO".capitalize())                 # Hello
print("WORLD".capitalize())                 # World
print("".capitalize())                      # (empty)

# swapcase — flip case per char.
print("Hello, World!".swapcase())           # hELLO, wORLD!
print("AbCdEf".swapcase())                  # aBcDeF

# casefold — lowercase (close to Python's casefold for ASCII).
print("HELLO".casefold())                   # hello
print("MiXeD".casefold())                   # mixed
