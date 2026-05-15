def fib_iter(n):
    a = 0
    b = 1
    i = 0
    while i < n:
        a, b = b, a + b
        i += 1
    return a

print(fib_iter(10))
