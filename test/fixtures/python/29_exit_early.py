# Regression: bare `exit()` translated to `var_exit()` (undefined) — the
# `exit` Kernel collision triggers Naming's var_ rewrite, and there was
# no Builtins emit clause to short-circuit it. See
# `Pylixir.Builtins.emit("exit", ...)` + py_main's `:pylixir_exit`
# catch wrapper (`Pylixir.Converter.wrap_exit_catch/1`). Adapted from an
# eval-corpus failure (compile_error--compile_quoted_raised, 2026-05-16);
# the `int(input())` / `map(int, input().split())` lines are rewritten
# with literal data so the fixture runs hermetically.
n = 0
if n == 0:
    print(0)
    exit()

print("unreachable")
print("also unreachable")
