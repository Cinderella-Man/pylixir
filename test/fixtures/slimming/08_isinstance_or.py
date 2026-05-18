# Targets T6: `isinstance` returns {:bool}; BoolOp Or of two
# isinstance calls also types as {:bool}. S1 elision drops the
# truthy? wrap; if no other truthy? user exists, the helper family
# tree-shakes entirely.

def classify(x):
    if isinstance(x, int) or isinstance(x, bool):
        return "numeric"
    return "other"

print(classify(5))
print(classify("hi"))
