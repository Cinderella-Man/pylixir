# Regression: `.pop()` on an expression receiver — e.g. `(s1 - s2).pop()`
# — fell through to the "method `.pop()` is not supported" branch.
# The bare-Name `s.pop()` path rebinds via single_target_assign, but
# expression receivers have nothing to rebind. Fix: added `pop` to
# attribute_methods' @set_methods (expression-context dispatcher) and
# a new `py_pop_any/1` runtime helper that pops an arbitrary element
# from a set or the last from a list. Adapted from an eval-corpus
# failure (unsupported--Call, 2026-05-16).
list1 = [1, 2, 3, 4, 5]
list2 = [3, 4, 5, 6, 7]
list3 = [5, 6, 7, 8, 9]

s1 = set(list1)
s2 = set(list2)
s3 = set(list3)

# Single-element set difference — `.pop()` returns the unique element.
diff_a = s1 - (s2 | s3)   # {1, 2}
diff_b = (s2 - s1) - s3   # {} — but here we use a non-empty case below

# Pop on an ephemeral set difference.
fixed = (s1 - s2 - s3).pop()  # one of {1, 2} — set order varies, sort to test
print(fixed in {1, 2})

# Pop on a singleton list literal expression.
print([42].pop())

# Capture-return on a bare Name still works (the existing rebind path).
xs = [10, 20, 30]
last = xs.pop()
print(last)
print(xs)
