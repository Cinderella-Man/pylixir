# Regression: `sys.stdout.flush()` raised UnsupportedNodeError,
# blocking 23 / 500 eval samples — the "interactive judging" pattern
# of printing then flushing each line. BEAM's IO is line-buffered to
# the group leader with no user-facing flush primitive, so this lowers
# to nil (a no-op). `sys.stderr.flush` gets matching treatment.
# `sys.stderr.write(s)` is wired to `IO.write(:stderr, s)` but isn't
# exercised here because stderr leaks past the golden-corpus stdout
# capture and clutters `mix test` output.

import sys

for line in ["a", "b", "c"]:
    print(line)
    sys.stdout.flush()

sys.stderr.flush()
print("done")
