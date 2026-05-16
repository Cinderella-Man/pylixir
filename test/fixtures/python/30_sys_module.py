# Regression: `import sys` raised `UnsupportedNodeError("Import")`. Fix:
# `Pylixir.Stdlib` registry now hosts a pluggable map of supported stdlib
# modules; `Pylixir.Stdlib.Sys` covers `argv`, `maxsize`, `exit(...)`,
# `stdout.write(...)`, and `stdin.read()`. Adapted from an eval-corpus
# failure (unsupported--Import, 2026-05-16); the original snippet used
# `sys.stdin.read().split()` (not hermetic — stdin is empty under test)
# plus a nested `def` (separate unsupported pattern), so this fixture
# exercises the parts of `sys` we now translate end-to-end.
import sys

print(sys.maxsize)

if sys.maxsize > 0:
    print("nonempty")
    sys.exit(0)

print("unreachable")
