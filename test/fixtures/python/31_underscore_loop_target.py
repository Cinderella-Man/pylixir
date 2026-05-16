# Regression: `for _ in xs:` inside an `if` body triggered the
# if/else state-tuple wrapper to thread `_` through both branches —
# producing Elixir `_ = if ... do _ else _ end`, which the parser
# rejects ("`_` can only be used inside patterns"). Fix: `_` is
# treated as a discard everywhere — `Pylixir.LoopAnalysis.target_names`
# skips it, `Pylixir.Converter.convert_loop_target` emits Elixir's `_`
# without binding to scope. Adapted from an eval-corpus failure
# (compile_error--compile_quoted_raised, 2026-05-16).
xs = [1, 2, 3]
if len(xs) > 0:
    for _ in xs:
        print("hi")

# Tuple-target with `_` as one element — also gets the discard
# treatment; only `x` is bound.
for _, x in [(0, 10), (0, 20)]:
    print(x)

print("done")
