# Regression: iterating a dict in Python yields KEYS (`for k in d:`,
# `list(d)`, `sorted(d)`, `min(d)`). Pylixir lowered these through
# Elixir's Map Enumerable, which yields `{k, v}` ENTRIES — so all
# these idioms quietly returned the wrong shape. Fix: route dict
# iteration through `py_iter_to_list/1` which uses `Map.keys` for
# maps. Applied at the for-loop emission site and to `list/sorted/
# min/max` builtins. Cheap no-op for the common list-iter case.

# for-loop over dict.
d = {(1, 2): "a", (3, 4): "b"}
for k in d:
    print(k)

# sorted(dict) — sorts keys.
print(sorted(d))                          # [(1, 2), (3, 4)]
print(sorted({"banana": 1, "apple": 2}))  # ['apple', 'banana']

# list(dict).
print(sorted(list({"x": 1, "y": 2})))     # ['x', 'y']

# min/max on dict — pick keys.
print(min({"banana": 1, "apple": 2, "cherry": 3}))   # apple
print(max({"banana": 1, "apple": 2, "cherry": 3}))   # cherry

# Dict literal in expression.
print(sorted({1: "a", 3: "c", 2: "b"}))   # [1, 2, 3]
