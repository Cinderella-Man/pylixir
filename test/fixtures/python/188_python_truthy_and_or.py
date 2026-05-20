# Regression: Pylixir translated Python's `a and b` / `a or b` directly
# to Elixir's `&&` / `||`. Elixir treats only `false` / `nil` as falsy,
# so `[] && X` returns `X` (not `[]`), and `while queue and cond:` with
# `queue == []` entered the loop body and crashed on the next
# `queue.popleft()`. Pylixir now folds non-bool operands through a
# `case` + `truthy?/1` to mirror Python's value-returning short-circuit.

# `[]` is Python-falsy; `[] and X` returns [].
empty_list = []
print(empty_list and "never reached")

# Same shape inside a while-guard — the original eval-corpus failure
# (seed_14646). The queue is empty so the loop body must NOT run.
queue = []
threshold = 5
current_end = 0
while queue and current_end <= threshold:
    print("BUG: entered body of `while [] and ...`")
    break
print("after-while")

# `0` is Python-falsy; `0 or "fallback"` returns "fallback".
print(0 or "fallback")

# `""` is Python-falsy.
print("" or "default")

# Non-empty list is truthy; `[1] and 99` returns 99.
print([1] and 99)

# Chain of `and` — first falsy wins.
print(1 and [] and "after")

# Chain of `or` — first truthy wins.
print(0 or "" or [] or "first-truthy")

# Statically-bool operands keep using Elixir's native `&&`/`||` (fast
# path); semantics already match Python.
a = True
b = False
print(a and b)
print(a or b)
