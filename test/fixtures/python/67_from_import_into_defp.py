# Regression: `from math import gcd` followed by `def main(): ... gcd(t, n)`
# compiled `defp main` at module scope but bound `gcd = fn ... end`
# inside py_main, so `main()` couldn't see `gcd`. Fix: ModuleAnalysis
# now treats `from <module> import <name>` as introducing a binding
# at py_main scope, so any FunctionDef that references the imported
# name gets demoted to a lambda alongside it. Adapted from an
# eval-corpus failure (compile_quoted_raised, 2026-05-16).
from math import gcd, floor

def main():
    print(gcd(12, 8))
    print(gcd(15, 25))
    print(floor(3.7))
    # Nested call should also resolve through the captured closure.
    return gcd(gcd(20, 12), 6)

print(main())
