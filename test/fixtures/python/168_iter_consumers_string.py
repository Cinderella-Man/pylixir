# Silent bug: `reversed("abc")`, `enumerate("ab")`, `zip("ab", "cd")`,
# `sum("12")`-style consumers all transpiled cleanly but crashed at
# runtime because their Elixir lowerings (`Enum.reverse/with_index/
# zip/reduce`) don't accept BitString. Fix: wrap iterable args in
# `py_iter_to_list` — same normalisation `list(s)` / `sorted(s)`
# already used. Companion to fixture 167 (Counter on string).
print(list(reversed("abc")))           # ['c', 'b', 'a']

for i, c in enumerate("xyz", 5):
    print(i, c)
# 5 x
# 6 y
# 7 z

print(list(zip("abc", "xyz")))         # [('a', 'x'), ('b', 'y'), ('c', 'z')]

# `sum` on a tuple-of-ints — Pylixir's iter coercion handles tuples too.
print(sum((1, 2, 3, 4)))               # 10

# Mixed tuple-of-strings reversed.
print(list(reversed(("first", "second", "third"))))
# ['third', 'second', 'first']
