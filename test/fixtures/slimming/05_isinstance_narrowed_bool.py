# Targets S1 + PR 12 narrowing: isinstance narrows x to int, then the
# `x == 0 or x == 1` test is a {:bool} so truthy? wrap drops.

def f(x):
    if isinstance(x, int):
        if x == 0 or x == 1:
            return "low"
        return "high"
    return "other"

print(f(0))
print(f(5))
