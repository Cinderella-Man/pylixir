# Silent bug (continued): `map(f, "abc")`, `filter(f, "abc")`,
# `any("a")`, `all("a")`, `tuple("abc")`, `set("abc")` all also
# crashed at runtime on strings — same Enumerable-BitString issue
# fixture 168 caught. Same fix: wrap iterable arg in py_iter_to_list.
print(list(map(lambda c: c.upper(), "abc")))    # ['A', 'B', 'C']
print(list(filter(lambda c: c >= 'b', "abc")))  # ['b', 'c']

# any / all over string truthiness — non-empty chars are truthy.
print(any("abc"))                      # True
print(all("abc"))                      # True
print(any(""))                         # False

# tuple/set over string iterates graphemes.
print(tuple("ab") == ('a', 'b'))       # True
s = set("hello")
print(sorted(s))                       # ['e', 'h', 'l', 'o']
