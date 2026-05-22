# Gap fill: augmented assignment to a nested subscript target
# (`d[a][b] += v`). The AugAssign target is `Subscript(Subscript(...))`,
# which must rebind the outermost name through nested py_setitem —
# otherwise the inner py_setitem result is discarded and the mutation
# is silently lost. Covers dict-of-dict, list-of-dict, and the
# defaultdict auto-vivification idiom from competitive code.
from collections import defaultdict

# dict-of-dict via nested defaultdict. The auto-vivified inner key
# must persist across repeated += on the same outer key.
char_dict = defaultdict(lambda: defaultdict(int))
char_dict["a"][0] += 1
char_dict["a"][0] += 2
char_dict["a"][5] += 7
char_dict["b"][0] += 3
print(char_dict["a"][0])  # 3
print(char_dict["a"][5])  # 7
print(char_dict["b"][0])  # 3

# list-of-dict: maps[i][k] += v.
maps = [defaultdict(int) for _ in range(3)]
maps[0][10] += 4
maps[0][10] += 1
maps[2][7] += 9
print(maps[0][10])  # 5
print(maps[2][7])   # 9

# Three levels deep, plain dicts.
grid = {0: {0: {0: 100}}}
grid[0][0][0] -= 40
print(grid[0][0][0])  # 60

# Accumulation driven by a loop, mirroring the eval-corpus shape.
s = "abacaba"
counts = defaultdict(lambda: defaultdict(int))
running = 0
for ch in s:
    counts[ch][running] += 1
    running += 1
print(counts["a"][0])  # 1
print(counts["a"][2])  # 1
print(counts["b"][1])  # 1
