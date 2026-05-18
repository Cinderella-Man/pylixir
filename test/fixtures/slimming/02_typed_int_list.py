# Targets S3: typed-list printing inlines the repr; no py_str / py_repr_*
# helpers should appear in the output.

print([1, 2, 3])
print([10, 20, 30])
print([])

xs = [4, 5, 6]
print(xs)
