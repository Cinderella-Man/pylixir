# Regression: `bisect.insort(xs, v)` inside a for-loop must thread `xs`
# through the loop accumulator. LoopAnalysis recognised heapq's
# statement-mutation calls but not bisect's, so the rebind was discarded
# each iteration and `xs` stayed at its pre-loop value (eval-corpus
# seed_3783, output_mismatch--18).
import bisect

xs = [1, 5, 10]
for v in [3, 7, 2, 8, 6]:
    bisect.insort(xs, v)
    # read back through the just-inserted state so a dropped rebind shows
    print(len(xs), xs[0], xs[-1])

print(xs)
