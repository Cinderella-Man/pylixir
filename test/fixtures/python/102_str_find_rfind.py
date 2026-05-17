# Regression: `str.find(sub, start)`, `str.find(sub, start, end)`,
# and `str.rfind` (any arity) raised "method `.X()` is not supported"
# — only 1-arg `find(sub)` had a clause. Fix: extended `find` clauses
# for 2 and 3 args, added `rfind` mirror; runtime helpers compute the
# index in the sliced substring and offset back to absolute. Adapted
# from common Python idioms.

# find with start.
print("abc abc".find("b"))         # 1
print("abc abc".find("b", 2))      # 5
print("abc abc".find("b", 6))      # -1

# find with start AND end.
print("abc abc".find("b", 0, 3))   # 1
print("abc abc".find("b", 0, 1))   # -1 (end excludes index 1)

# rfind — rightmost.
print("abc abc".rfind("b"))        # 5
print("abc abc".rfind("a"))        # 4
print("abc abc".rfind("z"))        # -1

# rfind with bounds.
print("abc abc".rfind("b", 0, 3))  # 1
print("abc abc abc".rfind("b", 2, 8))  # 5
