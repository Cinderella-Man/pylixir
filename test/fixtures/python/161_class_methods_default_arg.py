# Regression: methods with default args (`def update(self, i, delta=1)`)
# failed to compile because `emit_method` ignored `args.defaults`,
# emitting a 3-arity defp that the call site `ft.update(i)` couldn't
# reach. Loop 12 added `\\ default` syntax for trailing args, matching
# how regular `Pylixir.Nodes.Functions.build_param_asts/2` handles
# them.
#
# Also exercises the `{return_value, updated_self}` tuple shape for
# mutating methods that ALSO return a value (DSU.find pattern):
# my path-compressing find both mutates self and returns the root.

class DSU:
    def __init__(self, n):
        self.parent = list(range(n))

    def find(self, x):
        # mutates self (path compression), returns root
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a, b):
        ra = self.find(a)
        rb = self.find(b)
        if ra != rb:
            self.parent[ra] = rb

class FenwickTree:
    def __init__(self, size):
        self.size = size
        self.tree = [0] * (size + 1)

    def update(self, index, delta=1):    # ← default arg
        while index <= self.size:
            self.tree[index] += delta
            index += index & -index

    def query(self, index):
        res = 0
        while index > 0:
            res += self.tree[index]
            index -= index & -index
        return res

# Exercise default arg: omit delta, use the default of 1.
ft = FenwickTree(5)
ft.update(1)
ft.update(2)
ft.update(2)
print(ft.query(5))                 # 3
ft.update(3, 10)
print(ft.query(5))                 # 13

# Exercise the DSU return-value-AND-mutation: find both rebinds dsu
# (path compression) AND returns the root for the assign target.
dsu = DSU(6)
dsu.union(0, 1)
dsu.union(2, 3)
dsu.union(0, 2)
r0 = dsu.find(0)
r1 = dsu.find(3)
r2 = dsu.find(4)
print(r0 == r1)                    # True (all in one set)
print(r0 == r2)                    # False
