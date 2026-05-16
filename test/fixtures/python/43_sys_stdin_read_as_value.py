# Regression: `input = sys.stdin.read` (binding the method as a value
# for later call) raised "`sys.stdin.read` is not a supported stdlib
# attribute". Pylixir handled `sys.stdin.read()` (the call) but not
# the bare attribute access. Fix: `Pylixir.Stdlib.Sys.attribute/2`
# emits a zero-arg lambda. The subsequent `input()` resolves through
# the in-scope-anonymous-call path. Adapted from an eval-corpus
# failure (unsupported--Attribute, 2026-05-16).
import sys

reader = sys.stdin.read
data = reader()
if data == "":
    print("eof")
else:
    print("got: " + data.rstrip())

# Same for readline.
ln = sys.stdin.readline
first = ln()
print(first == "")
