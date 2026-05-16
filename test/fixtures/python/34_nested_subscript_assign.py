# Regression: `matrix[i][j] = v` raised "Assign target shape `Subscript`
# is not supported in T13 (non-Name-rooted subscript / Attribute /
# Starred / slice)" — T13 only handled depth-1 subscripts. Fix: chains
# rooted at a bare `Name` now lower to nested `py_setitem` /
# `py_getitem` calls. Adapted from an eval-corpus failure
# (unsupported--Assign, 2026-05-16).
matrix = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]

# Depth-2 setitem on every cell.
for i in range(3):
    for j in range(3):
        matrix[i][j] = i * 3 + j

for row in matrix:
    print(row)

# Single update plus subsequent read confirms the rebind preserves
# unrelated cells.
matrix[1][1] = 99
print(matrix[1][1])
print(matrix[0][0])
