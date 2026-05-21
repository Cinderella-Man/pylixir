# Gap fill: 162_church_numerals uses a ternary in a `return`, but no
# fixture exercises `x = a if cond else b` in an Assign-target
# position, in a comprehension element, or chained.

# Plain assignment ternaries.
n = 7
parity = "even" if n % 2 == 0 else "odd"
print(parity)

n = 12
parity = "even" if n % 2 == 0 else "odd"
print(parity)

# Ternary in a list-comp element.
xs = [1, 2, 3, 4, 5]
labels = ["lo" if x < 3 else "hi" for x in xs]
print(labels)

# Ternary in a function-call argument.
def show(label):
    print(label)


show("yes" if 1 < 2 else "no")
show("yes" if 1 > 2 else "no")

# Chained ternaries (a if c1 else (b if c2 else c)).
def classify(x):
    return "neg" if x < 0 else ("zero" if x == 0 else "pos")


print(classify(-5))
print(classify(0))
print(classify(5))
