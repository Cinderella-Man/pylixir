# Regression: `from itertools import permutations` bound permutations
# to `&py_permutations/1`. Calling `permutations(a, 3)` then failed
# at compile time ("expected a 2-arity function on call"). Fix:
# Context now tracks stdlib-alias origin; `emit_name_call` dispatches
# through the stdlib's call/4 when an aliased name is invoked, so all
# arities the stdlib supports work transparently. Adapted from an
# eval-corpus failure (compile_error--expected_a_2-arity_function_on_call_,
# 2026-05-16).
from itertools import permutations, combinations
from bisect import bisect_left, bisect_right

xs = [1, 2, 3]
# 1-arg permutations.
print(len(list(permutations(xs))))            # 6
# 2-arg permutations (the failing call shape).
print(len(list(permutations(xs, 2))))         # 6
print(len(list(permutations([1, 2, 3, 4], 3))))  # 24

# combinations with explicit r (only supported form).
print(len(list(combinations([1, 2, 3, 4], 2))))  # 6

# bisect 2-arg and 4-arg both work via the alias.
ys = [1, 3, 5, 7, 9, 11]
print(bisect_left(ys, 4))                  # 2
print(bisect_left(ys, 7, 2, 5))            # 3
print(bisect_right(ys, 5, 0, 6))           # 3
