def binary_search(xs, target):
    lo = 0
    hi = len(xs) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        v = xs[mid]
        if v == target:
            return mid
        if v < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return -1

print(binary_search([1, 3, 5, 7, 9, 11, 13, 15], 11))
