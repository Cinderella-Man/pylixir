# Regression: `s.split(sep, -1)` (Python's "no limit" idiom)
# crashed with `FunctionClauseError: no function clause matching in
# String.parts_to_index/1`. The codegen emitted
# `String.split(s, sep, parts: maxsplit + 1)` — for `-1` that's
# `parts: 0` which is invalid. Fix: recognise the literal `-1` at
# dispatch time and route to the plain `String.split/2` (which
# matches Python's no-limit semantics).

print("a,b,c,d".split(",", -1))       # ['a', 'b', 'c', 'd']
print("a,b,c,d".split(","))           # same — sanity
print("a,b,c,d".split(",", 1))        # ['a', 'b,c,d']  (bounded form still works)
print("a,b,c,d".split(",", 100))      # ['a', 'b', 'c', 'd']  (huge limit)
print("aXXbXX".split("XX", -1))       # ['a', 'b', '']
