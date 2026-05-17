# Regression: a Python identifier starting with `var_` (legal Python,
# common as `var_type`, `var_name`, etc.) raised "starts with a
# reserved Pylixir prefix". The prefix exists because Pylixir
# rewrites Python's `type` keyword to `var_type` — so naive lowering
# of the user's `var_type` would collide. Fix: user identifiers
# starting with `var_` get an extra `usr_` prefix on emission so they
# end up as `usr_var_type` and never collide with the keyword
# rewrite. Adapted from an eval-corpus failure
# (unsupported--Name, 2026-05-16).

# User uses var_-prefixed names.
var_type = "constant"
var_name = "alpha"
var_data = [1, 2, 3]

print(var_type)
print(var_name)
print(var_data)

# Mix with a Python-keyword rewrite — `type` becomes `var_type` in the
# emitted code; the user's `var_type` becomes `usr_var_type`; no clash.
def classify(x):
    if x == 0:
        var_kind = "zero"
    elif x > 0:
        var_kind = "pos"
    else:
        var_kind = "neg"
    return var_kind

print(classify(0))
print(classify(5))
print(classify(-3))
