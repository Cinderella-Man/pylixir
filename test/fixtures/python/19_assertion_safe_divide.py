def safe_divide(a, b):
    assert b != 0, "division by zero"
    return a / b

print(safe_divide(10, 2))
print(safe_divide(7, 4))
print(safe_divide(-15, 3))
