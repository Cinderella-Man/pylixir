# Regression: `sys.stdout.flush()` raised UnsupportedNodeError,
# blocking 23 / 500 eval samples — the "interactive judging" pattern
# of printing then flushing each line. BEAM's IO is line-buffered to
# the group leader with no user-facing flush primitive, so this lowers
# to nil (a no-op). `sys.stderr.flush` and `sys.stderr.write(s)` get
# matching treatment (write routes through `IO.write(:stderr, s)`).

import sys

for line in ["a", "b", "c"]:
    print(line)
    sys.stdout.flush()

# stderr.write — separated to stderr; not part of stdout golden compare.
sys.stderr.write("ignored\n")
sys.stderr.flush()

print("done")
