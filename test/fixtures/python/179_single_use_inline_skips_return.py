# Regression: the single-use-closure-inliner spliced a zero-arg
# `def main()` body into its sole call site at module scope. When
# the body contained a `return` (early-exit guard), the spliced
# `Return` node lost its enclosing function — the converter saw it
# at module scope with `context.return_mode == nil` and raised
# `UnsupportedNodeError(node_type: "Return", hint: "`return` outside
# a function is a Python SyntaxError")`. Real sample: any
# `from collections import Counter; def main(): ... return; ...
# main()` from the rStar-Coder synthetic_sft window (jumped
# unsupported--Return from 1.4% → 1.9% in the 2026-05-19 run).
#
# Fix: `Pylixir.SingleUseClosureInline.inline_target/1` now rejects
# statement-position targets whose body carries a `Return`/`Yield`/
# `YieldFrom` at the function's own level (descending through
# control-flow, but stopping at nested defs/lambdas/classes whose
# Returns belong to their own enclosing function). Inlining is
# skipped; the def survives as a demoted closure inside py_main and
# its `return` keeps function-exit semantics via the
# `throw {:pylixir_return, _}` lowering.

from collections import Counter


def main():
    arr = [1, 2, 2, 3, 3, 3]
    if not arr:
        print("empty")
        return
    freq = Counter(arr)
    print(sorted(freq.items()))  # [(1, 1), (2, 2), (3, 3)]


if __name__ == "__main__":
    main()
