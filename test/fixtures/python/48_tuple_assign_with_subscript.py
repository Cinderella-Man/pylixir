# Regression: `t[i], t[i+1] = t[i+1], t[i]` (the swap-via-tuple-Assign
# idiom) raised "tuple-Assign target requires all elements to be
# `Name` nodes; got `Subscript`". Fix: a new mixed-tuple-assign
# emitter temp-binds every RHS value first (so reads can't be
# clobbered by writes), then applies each LHS in order — Names become
# normal binds, Subscripts become `py_setitem` rebinds. Adapted from
# an eval-corpus failure (unsupported--Assign, 2026-05-16).

# Original repro: in-place swap during a sort pass.
t = [4, 2, 3, 1]
for i in range(len(t) - 1):
    if t[i] > t[i + 1]:
        t[i], t[i + 1] = t[i + 1], t[i]
print(t)

# Mixed Name + Subscript — `y` is both LHS and RHS, must not be
# clobbered before the second LHS reads it. (This is what motivated
# always temp-binding RHS values, even trivial Names.)
xs = [10, 20]
y = 99
y, xs[0] = xs[0], y
print(y)
print(xs)
