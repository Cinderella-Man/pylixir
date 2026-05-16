# Regression: `sys.stdin.readline()` raised "not a supported stdlib
# call". Fix wires it to a `py_stdin_readline/0` runtime helper that
# returns one line *including* the trailing newline (or "" at EOF).
# Adapted from an eval-corpus failure (unsupported--Call, 2026-05-16).
#
# The golden-corpus runner invokes CPython via `System.cmd` (no stdin
# piped → empty stdin) and Pylixir via `ExUnit.CaptureIO.capture_io/1`
# (also empty stdin). Both runtimes therefore see EOF on every read,
# and `sys.stdin.readline()` returns "" in both. This fixture pins
# that invariant. Trailing-newline preservation (the other half of
# readline's semantics) is covered by `runtime_helpers_test.exs`,
# which pipes content via capture_io's input argument.
import sys

line = sys.stdin.readline()
if line == "":
    print("eof")
else:
    print("got: " + line.rstrip())

# A repeat call at EOF is still "" — idempotent.
second = sys.stdin.readline()
print(line == second)
