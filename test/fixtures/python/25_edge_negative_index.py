# RFC §6 / §9: Python's negative indices wrap from the end. py_getitem
# must handle this for lists, tuples, and strings.
xs = [10, 20, 30, 40, 50]
print(xs[-1])
print(xs[-2])
print(xs[-5])

t = (10, 20, 30)
print(t[-1])
print(t[-2])

s = "hello"
print(s[-1])
print(s[-5])
