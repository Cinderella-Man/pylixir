xs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
evens = filter(lambda x: x % 2 == 0, xs)
squared = map(lambda x: x * x, evens)
print(sum(squared))
