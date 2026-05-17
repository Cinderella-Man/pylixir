# Regression: a top-level `def f(...)` whose body referenced top-level
# *mutable* state (`parts`, `assembly` dicts populated by a runtime
# loop) compiled to `defp f(...)` at module scope, which couldn't see
# bindings introduced inside `py_main`. Fix: ModuleAnalysis now
# detects such "closure" defs and demotes them to runtime statements
# at their original position; Converter emits them as `f = fn ... end`
# lambda bindings that close over py_main's scope. Includes the
# recursive-self trick for self-referential defs. Adapted from an
# eval-corpus failure (compile_quoted_raised, 2026-05-16).
#
# Note: an earlier version of this fixture also memoized via a
# `computed = {}` module-level dict mutated inside `compute`. That
# pattern is now rejected by `ModuleAnalysis.reject_mutated_in_top_defs!`
# (immutable @-attrs can't model in-def subscript-assign), and the
# rejection's own regression coverage lives in transpile_test.exs
# under "module-level dict mutated inside top-level def".
parts = {}
parts["a"] = 1
parts["b"] = 2

assembly = {}
assembly["c"] = ["a", "b"]

def compute(part):
    direct = parts.get(part, 999)
    if part in assembly:
        total = 0
        for child in assembly[part]:
            total += compute(child)
        return min(direct, total)
    return direct

print(compute("a"))
print(compute("b"))
print(compute("c"))
