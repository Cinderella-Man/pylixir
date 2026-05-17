# Regression: `dict.fromkeys`, `dict.popitem`, and `dict.clear` were
# unsupported method dispatches and fell through to the generic
# attribute-call fallback (which raised). Added dispatch clauses in
# `Pylixir.Nodes.AttributeMethods` plus `py_dict_fromkeys/2` and
# `py_dict_popitem/1` runtime helpers. `clear()` in expression context
# lowers to `nil` (matching Python's None return) — the rebind form
# is handled by `Pylixir.Nodes.Mutations`.

# fromkeys with explicit default.
d1 = dict.fromkeys(["a", "b", "c"], 0)
print(sorted(d1.items()))            # [('a', 0), ('b', 0), ('c', 0)]

# fromkeys with no default (None / nil).
d2 = dict.fromkeys(["x", "y"])
print(sorted(d2.items()))            # [('x', None), ('y', None)]

# fromkeys with a tuple iterable.
d3 = dict.fromkeys((1, 2, 3), "v")
print(sorted(d3.items()))            # [(1, 'v'), (2, 'v'), (3, 'v')]

# popitem — we just check the result is a (k, v) drawn from the dict.
# (Order is unspecified across implementations.)
d4 = {"only": 42}
k, v = d4.popitem()
print(k, v)                          # only 42

# clear() — expression context returns None; print(None) prints "None".
d5 = {"a": 1}
print(d5.clear())                    # None
