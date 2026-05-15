import math

def distance(x1, y1, x2, y2):
    dx = x2 - x1
    dy = y2 - y1
    return math.sqrt(dx * dx + dy * dy)

print(distance(0, 0, 3, 4))
print(distance(0, 0, 5, 12))
