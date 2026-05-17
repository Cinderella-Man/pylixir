# Regression: `class Foo: ...` was rejected at transpile time
# ("Python classes are not supported"). Loops 1-9 of the eval-corpus
# work added a minimal data-class lowering:
#
#   * `class C: def __init__(self, ...): self.x = ...; self.y = ...`
#     becomes `defp __cls_C__init__(...)` that returns a map.
#   * `C(args)` calls the constructor.
#   * `obj.attr` reads via `Map.fetch!(obj, :attr)`.
#   * Read-only methods (no `self.x = ...`) lower to
#     `defp __cls_C_<method>(self, ...)` returning the value.
#   * Mutating methods return updated `self`; the Expr clause rebinds
#     `obj = __cls_C_<method>(obj, args)` so the caller sees the
#     change.
#   * `self.attr[i] = v` and `self.attr[i] += d` rewrites stay
#     inside the self map.
#   * Classes nested inside `def main():` are hoisted to module top
#     during ModuleAnalysis (`extract_classes/1` walks function bodies).

# 1. Plain data class — instantiation, attribute reads, methods.
class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y

    def magnitude_sq(self):
        return self.x * self.x + self.y * self.y

    def shifted_by(self, dx, dy):
        return Point(self.x + dx, self.y + dy)

p = Point(3, 4)
print(p.x, p.y)
print(p.magnitude_sq())
q = p.shifted_by(10, 20)
print(q.x, q.y, q.magnitude_sq())

# 2. Mutating method — caller rebind via Expr clause.
class Counter:
    def __init__(self, start):
        self.n = start

    def bump(self):
        self.n = self.n + 1

    def value(self):
        return self.n

c = Counter(0)
c.bump()
c.bump()
c.bump()
print(c.value())            # 3

# 3. Class nested inside a function — hoisted to module top.
def run_dsu():
    class DSU:
        def __init__(self, n):
            self.parent = list(range(n))

        def find(self, x):
            root = x
            while self.parent[root] != root:
                root = self.parent[root]
            return root

        def union(self, a, b):
            ra = self.find(a)
            rb = self.find(b)
            if ra != rb:
                self.parent[ra] = rb

    dsu = DSU(5)
    dsu.union(0, 2)
    dsu.union(2, 4)
    print(dsu.find(0) == dsu.find(4))   # True
    print(dsu.find(1) == dsu.find(3))   # False

run_dsu()

# 4. FenwickTree-shape: `self.tree[i] += d` self-attr aug-assign.
class FenwickTree:
    def __init__(self, size):
        self.size = size
        self.tree = [0] * (self.size + 1)

    def update(self, index, delta):
        while index <= self.size:
            self.tree[index] += delta
            index += index & -index

    def query(self, index):
        res = 0
        while index > 0:
            res += self.tree[index]
            index -= index & -index
        return res

ft = FenwickTree(8)
ft.update(1, 5)
ft.update(3, 2)
ft.update(8, 9)
print(ft.query(1))          # 5
print(ft.query(3))          # 7
print(ft.query(8))          # 16
