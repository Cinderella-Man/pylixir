# Gap fill: no existing fixture implements a sort algorithm by hand
# (20_sort_with_key uses builtin `sorted`). Bubble-sort exercises
# (a) nested loops over `range(len(xs))`, (b) tuple-swap on Subscript
# targets `xs[i-1], xs[i] = xs[i], xs[i-1]`, and (c) in-place list
# mutation visible after return.

def bubble_sort(xs):
    n = len(xs)
    for _ in range(n):
        for i in range(1, n):
            if xs[i] < xs[i - 1]:
                xs[i - 1], xs[i] = xs[i], xs[i - 1]
    return xs


data = [14, 11, 19, 5, 16, 10, 12]
print(bubble_sort(data))

# Empty + single-element edge cases.
print(bubble_sort([]))
print(bubble_sort([42]))

# Already-sorted is a no-op.
print(bubble_sort([1, 2, 3]))
