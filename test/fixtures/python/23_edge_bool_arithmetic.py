# RFC §6.11: in Python, True == 1 and False == 0 in arithmetic contexts.
# Elixir's `+` doesn't accept booleans; py_add must promote them.
print(True + True)
print(True + False)
print(False + False)
print(True * 3)
print(True - False)
print(5 + True)
print(sum([True, False, True, True]))

# NOTE: `True == 1` would return False here (RFC §6.12 known limitation)
# because Elixir's `==` doesn't coerce booleans. Documented as a gap.
