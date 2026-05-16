# Regression: a for-loop's target (`for s in ...:`) bound `s` into the
# converter's scope and the binding leaked AFTER the loop. A later
# for-loop that body-assigned `s = ...` then saw `s` as pre-bound and
# emitted `s` (not `nil`) in its Enum.reduce initial accumulator —
# producing `undefined variable "s"` at compile.
#
# Fix: `Pylixir.Nodes.Loop.emit_for/2` now saves+restores scopes
# around the loop body (matching the comprehension emitter's pattern),
# then re-binds only the *threaded* names that the accumulator
# actually exposes. Adapted from an eval-corpus failure
# (compile_error--compile_quoted_raised, 2026-05-16).

# Two sibling for-loops where the second body-assigns a name that
# happens to match the first loop's target.
words = ["foo", "bar"]
for s in words:
    print(s)

digits = [10, 20, 30]
results = []
for i in range(len(digits)):
    s = digits[i]            # second loop body-assigns `s` — must not
    results.append(s + 1)    # see a leaked binding from the first loop
print(results)

# Body-assigned vars DO survive the loop (Python's flat-scope rule).
acc = 0
for x in [1, 2, 3]:
    acc = acc + x
print(acc)
