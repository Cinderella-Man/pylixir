def describe(x):
    if isinstance(x, int):
        return "int"
    if isinstance(x, str):
        return "str"
    if isinstance(x, list):
        return "list"
    return "other"

print(describe(5))
print(describe("hi"))
print(describe([1, 2]))
print(describe(3.14))
