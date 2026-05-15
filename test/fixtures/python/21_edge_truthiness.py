def check(v):
    if v:
        return "truthy"
    else:
        return "falsy"

# Python-falsy values that are TRUTHY in Elixir — these probe the truthy? helper.
print(check(0))
print(check(0.0))
print(check(""))
print(check([]))
print(check({}))
print(check(None))
print(check(False))

# Genuinely truthy.
print(check(1))
print(check("x"))
print(check([0]))
print(check([False]))
