# Regression: a class method that mutates self only INDIRECTLY (via a
# call to another mutating method) was classified `:read_only`, so the
# call-site skipped the obj-rebind AND the bare-name `.add(...)` got
# stolen by `Pylixir.Nodes.Mutations` as if it were Python set's `.add`.
# Fix: fixpoint the mutating-methods set over `self.<m>(...)` calls so
# wrapper methods inherit `:mutating` from their callees. Adapted from
# an eval-corpus failure (synthetic_sft sample 1052, 2026-05-18).
class Counter:
    def __init__(self):
        self.n = 0

    def bump(self, k):
        self.n += k

    def add(self, k):
        # Indirect mutation via self.bump → must still propagate.
        self.bump(k)

    def add2(self, a, b, c):
        # Same shape with multiple args; previously triggered the
        # "mutation method `.add(3 args)` is not supported" hint when
        # the catch-all Mutations rejection fired.
        self.bump(a)
        self.bump(b)
        self.bump(c)


c = Counter()
c.add(5)
print(c.n)         # 5

c.add2(1, 2, 3)
print(c.n)         # 11
