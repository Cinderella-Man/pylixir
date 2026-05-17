# Regression: `min(xs, key=fn)` / `max(xs, key=fn)` silently dropped
# the `key=` kwarg and lowered to bare `Enum.min/max(xs)` — wrong
# answer for any element where the natural order differs from the
# keyed order. Fix: route to `Enum.min_by`/`max_by` when `key=` is
# present, combined with `default=` via the empty_fallback form.

# By key — pick by 2nd tuple element.
xs = [(1, "b"), (2, "a"), (3, "c")]
print(min(xs, key=lambda p: p[1]))    # (2, 'a')
print(max(xs, key=lambda p: p[1]))    # (3, 'c')

# By key — shortest string.
print(min(["hi", "hello", "x"], key=len))      # x
print(max(["hi", "hello", "x"], key=len))      # hello

# default= with empty iter.
print(min([], default=99))                     # 99
print(max([], default=-1))                     # -1

# key= AND default= on empty.
print(min([], key=lambda x: x, default=42))    # 42
print(max([], key=abs, default=0))             # 0

# Numeric key inverting order.
print(min([3, 1, 2], key=lambda x: -x))        # 3 (smallest -x → largest x)
