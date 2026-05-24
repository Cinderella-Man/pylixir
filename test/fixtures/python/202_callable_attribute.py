# Regression: calling a *callable stored in an instance attribute* —
# `self.op(a, b)` where `op` was assigned in `__init__` — was rejected as
# an unsupported method `.op()`. Methods/attributes on classes already
# work; the gap was the call dispatch routing `obj.attr(args)` to the
# method table instead of reading the attribute and calling its value.
# Adapted from an eval-corpus failure (unsupported--Call, SegmentTree
# with a `self.func` combiner).


class Acc:
    def __init__(self, op):
        self.op = op

    def apply(self, a, b):
        return self.op(a, b)


add = Acc(lambda x, y: x + y)
print(add.apply(2, 3))  # 5

mul = Acc(lambda x, y: x * y)
print(mul.apply(4, 5))  # 20

# The combiner reads other instance state too (closer to the SegmentTree
# shape: `self.func(self.tree[i], self.tree[j])`).
data = Acc(lambda a, b: max(a, b))
print(data.apply(7, 2))  # 7
