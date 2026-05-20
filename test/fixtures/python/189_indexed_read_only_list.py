# Read-only indexed access on a `list(...)`-bound name — the
# canonical alist (frozen-list) optimisation target. Before P5, every
# `x[i]` read walked the cons cells (O(n) per read); the alist wraps
# the storage in a tuple so `x[i]` becomes `elem/2` (O(1)).
#
# Source data is hard-coded so the golden-corpus harness can run this
# without stdin. The actual eval-corpus shape uses
# `list(map(int, input().split()))` for 100k-element inputs; semantics
# are identical, only the size differs.
#
# See `docs/08_o1-indexed-lists-py-alist.md`.

src_x = [10, 30, 50, 70, 90]
src_y = [20, 40, 60, 80, 100]

x = list(src_x)
y = list(src_y)

# Two-pointer merge — the inner loop hammers `x[i]` and `y[j]`, the
# exact pattern that was timing out at scale before this change.
i = 0
j = 0
merged_sum = 0
while i < len(x) and j < len(y):
    if x[i] < y[j]:
        merged_sum += x[i]
        i += 1
    else:
        merged_sum += y[j]
        j += 1
while i < len(x):
    merged_sum += x[i]
    i += 1
while j < len(y):
    merged_sum += y[j]
    j += 1

print(merged_sum)
print(len(x), len(y))
print(x[0], x[-1])
print(y[0], y[-1])

# Iteration via `for` and a few read-only builtins — every consumer
# routes through `coerce_iter`, which sees `is_list?({:py_alist, _})`
# is false and wraps in `py_iter_to_list` automatically.
for v in x:
    print(v)
print(sum(x), min(x), max(x))
print(sorted(y, reverse=True))
