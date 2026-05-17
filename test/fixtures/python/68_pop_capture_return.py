# Regression: `x = stack.pop()` and `a, b = stack.pop()` raised
# "method `.pop()` is not supported" because the capture-return form
# only had a statement-context handler (which discards the popped
# value). Fix: new `single_target_assign` clauses lower the
# capture-return form to `{popped, stack} = py_pop_last(stack)`
# (polymorphic list/dict via the new py_pop_* helpers). Adapted from
# an eval-corpus failure (unsupported--Call, 2026-05-16).

# List pop, no args — defaults to last element.
stack = [1, 2, 3, 4]
last = stack.pop()
print(last)        # 4
print(stack)       # [1, 2, 3]

# List pop, indexed.
nums = [10, 20, 30, 40]
mid = nums.pop(1)
print(mid)         # 20
print(nums)        # [10, 30, 40]

# Tuple-destructure capture (the popped element is itself a tuple).
pairs = [(1, "a"), (2, "b"), (3, "c")]
n, s = pairs.pop()
print(n)           # 3
print(s)           # c
print(pairs)       # [(1, 'a'), (2, 'b')]

# Dict pop with default.
d = {"x": 1, "y": 2}
v = d.pop("z", -1)
print(v)           # -1
print(sorted(d.items()))

# Dict pop existing key.
v2 = d.pop("x")
print(v2)          # 1
print(sorted(d.items()))
