# Regression: `set()` raised "`set/0` is not a supported Python builtin
# call shape" — the zero-arg form wasn't in `Pylixir.Builtins.emit/3`.
# Fix: every conversion-constructor builtin (`int`/`str`/`bool`/`float`/
# `list`/`tuple`/`set`/`dict`) now also handles the no-arg case and
# emits its Elixir empty/zero-value equivalent. Adapted from an
# eval-corpus failure (unsupported--Call, 2026-05-16).

# The original repro: build a set, mutate it, membership-test.
collection = set()
collection.add(5)
collection.add(7)
collection.discard(7)
collection.add(9)

for x in [5, 7, 9]:
    print(1 if x in collection else 0)

# The rest of the family — each constructor returns Python's
# documented zero/empty value.
print(int())      # 0
print(str())      # (empty string — prints just a newline)
print(bool())     # False
print(float())    # 0.0
print(list())     # []
print(dict())     # {}
