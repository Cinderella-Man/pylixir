# Regression: ASCII-uppercase-leading Python identifiers used to render as
# Elixir aliases, breaking tuple-unpack (`{W, H} = ...`), for-loop targets
# (`fn I -> ... end`), and later reads (`range(H)`). See Pylixir.Naming
# Category 4 — alias-shaped. Adapted from an eval-corpus failure
# (compile_error--compile_quoted_raised, 2026-05-16).
W, H = 4, 3
grid = [
    [1, 1, 0, 0],
    [1, 1, 0, 0],
    [0, 0, 1, 0],
]

perimeter = 0
directions = [(-1, 0), (1, 0), (0, -1), (0, 1)]

for i in range(H):
    for j in range(W):
        if grid[i][j] == 1:
            for d in directions:
                ni = i + d[0]
                nj = j + d[1]
                if ni < 0 or ni >= H or nj < 0 or nj >= W:
                    perimeter += 1
                else:
                    if grid[ni][nj] == 0:
                        perimeter += 1

print(perimeter)
