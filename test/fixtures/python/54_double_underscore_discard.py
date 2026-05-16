# Regression: `for __ in range(n)` emitted Elixir code with `__` as
# a variable, but `__` is Elixir's compiler-variable prefix
# (`__MODULE__` / `__ENV__` / …) and the parser rejects bare `__`.
# Fix: every all-underscore name (`_`, `__`, `___`, …) is treated as
# Python's throwaway / discard. Adapted from an eval-corpus failure
# (compile_error--unknown_compiler_variable, 2026-05-16).

# Original idiom: 2D-array initialization with two throwaway loops.
m = 3
matrix = [[0 for _ in range(m)] for __ in range(m)]
print(matrix)

# Tuple-target with mixed throwaways.
for _, x in [(0, 10), (0, 20), (0, 30)]:
    print(x)

# Longer throwaway as inner loop var.
for ___ in range(2):
    print("tick")
