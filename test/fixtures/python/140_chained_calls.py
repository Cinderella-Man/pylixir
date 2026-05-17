# Regression: `f(x)(y)` and `(lambda x: ...)(arg)` (call on a Call,
# Lambda, Subscript, or IfExp result) raised "unsupported call-target
# shape `Call`; expected `Name` or `Attribute`". Added a dispatch
# clause that lowers to Elixir's anonymous-call form `(callable).(args)`.

# Returning a lambda from a function — classic curry.
def make_mult(n):
    return lambda x: x * n

print(make_mult(3)(4))                  # 12
print(make_mult(10)(5))                 # 50

# Immediately-invoked lambda.
print((lambda x, y: x + y)(7, 8))       # 15

# Lambda stored, then called via a dict/list lookup (Subscript on
# callable, then call).
ops = {"add": lambda a, b: a + b, "mul": lambda a, b: a * b}
print(ops["add"](2, 3))                 # 5
print(ops["mul"](4, 5))                 # 20

# IfExp returning a callable.
flag = True
fn = (lambda x: x * 2) if flag else (lambda x: x + 100)
print(fn(7))                            # 14

# Direct IfExp call form (less common but legal).
print(((lambda x: x * 2) if True else (lambda x: 0))(9))  # 18
