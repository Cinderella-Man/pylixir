# Regression: a top-level `MOD = 10**9 + 7` was not constant-foldable
# (BinOp on Constants), so ModuleAnalysis didn't promote it to a
# module attribute. The fallback emitted `var_MOD = py_add(py_pow(10, 9), 7)`
# inside `py_main`, then references inside `defp main()` failed
# because `defp` doesn't see py_main's local bindings. Fix:
# `literal?/1` now accepts UnaryOp/BinOp on literals, and
# `convert_module_attrs` constant-folds via `fold_literal_value/1`
# so the resulting `@var_MOD 1_000_000_007` is a pure compile-time
# value. Adapted from an eval-corpus failure
# (compile_quoted_raised, 2026-05-16).
MOD = 10**9 + 7

def main():
    n = 5
    inv = pow(2, MOD - 2, MOD)
    print((inv * 2) % MOD)
    print(MOD)
    print(n * MOD % MOD)

main()
