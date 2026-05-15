def classify(n):
    if n < 0:
        return "negative"
    if n == 0:
        return "zero"
    if n < 10:
        return "small"
    if n < 100:
        return "medium"
    return "large"

print(classify(-5))
print(classify(0))
print(classify(7))
print(classify(42))
print(classify(1000))
