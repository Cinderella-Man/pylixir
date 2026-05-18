# Targets T7: function-arg return-type propagation. `map(double, ...)`
# now types as `{:list, {:int}}` via `function_return_type` looking up
# fn_signatures. S3's inline path then fires on print, dropping the
# py_str / py_repr_* / py_str_float chain entirely.

def double(x):
    return x * 2

print(list(map(double, [1, 2, 3])))
print(list(map(lambda y: y + 10, [4, 5, 6])))
