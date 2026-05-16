# Regression: `for (r, c), v in d.items():` raised "for-loop
# tuple-target element must be a Name; got `Tuple`". Fix:
# `convert_loop_target` now recurses through nested Tuples of Names
# via a new `convert_loop_target_elt` helper, producing nested Elixir
# tuple patterns. Adapted from an eval-corpus failure
# (unsupported--For, 2026-05-16).

# Original-corpus idiom: iterating a dict-of-tuple-keys.
bonuses = {(1, 2): 10, (3, 4): 20, (5, 6): 30}
total = 0
for (r, c), v in sorted(bonuses.items()):
    print(r, c, v)
    total += v
print(total)

# Deeper nesting — three levels.
pairs = [((1, 2), 3, 4), ((5, 6), 7, 8)]
for (a, b), c, d in pairs:
    print(a, b, c, d)
