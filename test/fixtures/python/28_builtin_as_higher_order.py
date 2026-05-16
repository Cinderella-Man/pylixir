# Regression: bare references to Python builtins (`int`, `str`) passed
# to higher-order functions used to emit undefined Elixir variables —
# `Enum.map(xs, int)` rather than `Enum.map(xs, fn x -> py_int(x) end)`.
# See Pylixir.Builtins.unary_capturable?/1. Adapted from an eval-corpus
# failure (compile_error--compile_quoted_raised, 2026-05-16); the
# original `t = int(input())` / `map(int, input().split())` is rewritten
# with literal data so the fixture runs hermetically.
strs = ["1", "2", "3", "4"]
nums = list(map(int, strs))
print(sum(nums))

b = [3, 0, 5, 0, 7]
a = [1 if x == 0 else 0 for x in b]
print(' '.join(map(str, a)))
