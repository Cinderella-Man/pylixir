# Gap fill: chained assignment `a = b = c = 0` doesn't appear in any
# existing fixture. Python's AST shape is `Assign(targets=[a,b,c],
# value=0)` with multiple targets rather than nested Assigns; tests
# that all bindings receive the value and rebinding propagates.

a = b = c = 0
print(a, b, c)

x = y = [1, 2, 3]
print(x)
print(y)
print(x is y)  # True — both names bind to the same list object

# Rebinding one of them does NOT affect the other.
x = [9, 9, 9]
print(x)
print(y)

# Chained assign of a function-call result — value evaluated once.
def make():
    print("called")
    return 42


a = b = make()
print(a, b)
