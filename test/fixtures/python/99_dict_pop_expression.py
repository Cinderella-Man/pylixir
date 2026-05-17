# Regression: `d.pop(k)` and `d.pop(k, default)` in expression
# context (`print(d.pop(k))`) raised "method `.pop()` is not
# supported" — only the 0-arg form was handled, and only the bare-Name
# Assign-RHS form had the 1/2-arg rebind clauses. Fix: attribute_methods
# now routes 1-arg and 2-arg `.pop` to value-only helpers
# (`py_pop_value` / `py_pop_value_default`) that return the looked-up
# value without rebinding. Mutation is lost in expression context;
# the `x = d.pop(k)` Assign-RHS form keeps the rebind.

# 1-arg dict pop in print().
d = {"a": 1, "b": 2}
print(d.pop("a"))               # 1

# 2-arg dict pop with default (missing key).
d2 = {"x": 10}
print(d2.pop("missing", -1))    # -1
print(d2.pop("x", -1))          # 10

# Inside a conditional.
config = {"verbose": True}
if config.pop("verbose", False):
    print("verbose mode")

# Inside arithmetic.
counts = {"apple": 3, "banana": 5}
total = counts.pop("apple", 0) + counts.pop("banana", 0)
print(total)                    # 8

# Note: because pop is value-only in expression context, `d` retains
# the keys we "popped" — that's a known tradeoff (the Assign-RHS
# form `x = d.pop(k)` does rebind).
