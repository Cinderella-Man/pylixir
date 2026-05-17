# Regression: `for line in sys.stdin:` and `[... for line in sys.stdin]`
# raised "bare `sys.stdin` is not supported — use sys.stdin.read()".
# Fix: `Pylixir.Stdlib.Sys.attribute(["stdin"], _)` now lowers to
# `IO.stream(:stdio, :line)` — Erlang's line-mode stdin reader,
# which is iterable and yields each line *with* its trailing
# newline (matches CPython's `for line in sys.stdin`).
# `sys.stdin.read()` / `sys.stdin.readline()` use separate
# multi-segment clauses and are unaffected. Adapted from
# eval-corpus failures (unsupported--Attribute, 2026-05-16).
import sys

# Golden harness pipes /dev/null to stdin, so the iterations below
# produce no output beyond the markers; the test confirms the
# transpile + compile path works.
lines = [line.strip() for line in sys.stdin]
print(len(lines))                    # 0 (empty stdin)

for line in sys.stdin:
    print(line.strip())
print("done")
