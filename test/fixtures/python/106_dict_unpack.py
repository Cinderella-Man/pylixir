# Regression: `{**d}` dict-unpack inside a dict literal raised
# "dict-unpack is not supported". Fix: the Dict converter now batches
# consecutive non-unpack pairs and chains `Map.merge` across batches.
# `{**d1, "k": v, **d2}` lowers to `Map.merge(Map.merge(d1, %{"k" => v}), d2)`.
# Common idiom for "merge dicts and override fields".

# Simple merge.
d1 = {"a": 1, "b": 2}
d2 = {"c": 3}
merged = {**d1, **d2}
print(sorted(merged.items()))                # [("a", 1), ("b", 2), ("c", 3)]

# Override values from the second dict.
defaults = {"color": "red", "size": "M"}
overrides = {"size": "L"}
final = {**defaults, **overrides}
print(final["color"], final["size"])         # red L

# Add new keys with literal entries between unpacks.
base = {"a": 1}
plus = {**base, "b": 2, "c": 3}
print(sorted(plus.items()))                   # [("a", 1), ("b", 2), ("c", 3)]

# Multiple unpacks + literals interleaved.
x = {"x": 10}
y = {"y": 20}
big = {**x, "mid": 50, **y, "end": 99}
print(sorted(big.items()))                    # [("end", 99), ("mid", 50), ("x", 10), ("y", 20)]

# Empty unpack.
print({**{}})                                 # {}
print({**{}, "k": 1})                        # {'k': 1}
