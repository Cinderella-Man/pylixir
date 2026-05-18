# Targets S1 + S2: bool prints typed via Compare result; the test value
# is `{:bool}` so truthy? wrap drops (S1), and the print-of-bool uses
# `py_bool_str` (S2) instead of inline if/else.

print(1 == 1)
print(1 != 2)
print(3 < 5)
print("a" == "a")

if 1 == 1:
    print("yes")

if 5 > 0 or 10 < 0:
    print("yes")
