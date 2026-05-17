# Regression: list comprehensions inside `while` bodies (`while ...:
# stuff = [B[i] for i in range(n)]`) read outer-scope names like `B`
# and `n`, but the while-rewriter's `read_only` analysis used the
# scope-aware `walk_scope`, which stopped at comprehension boundaries
# and missed those reads. The lifted `defp while_<n>/<arity>` helper
# was then missing those params, producing "undefined variable" at
# compile time. Fix: in `Pylixir.LoopAnalysis`, treat comprehensions
# as transparent for *referenced* names — collect every name read in
# the comp's elt / generators' iter / ifs, minus the for-targets the
# comp itself binds.

def first_two_each(B_toys, n):
    Wb = 2
    left = 0
    right = 5
    out = []
    while left <= right:
        mid = (left + right) // 2
        # Comp reads B_toys + Wb from outer scope.
        Wgroup = [B_toys[i][0] for i in range(Wb)]
        out.append((mid, Wgroup))
        left = mid + 1
    return out

print(first_two_each([(1, 2), (3, 4)], 5))


# DictComp + SetComp variants inside the same while.
def comps_in_while(xs, n):
    i = 0
    seen = []
    while i < 1:
        d = {k: k * 2 for k in xs if k < n}
        s = {x + n for x in xs}
        seen.append((sorted(d.items()), sorted(s)))
        i += 1
    return seen

print(comps_in_while([1, 2, 3], 3))
