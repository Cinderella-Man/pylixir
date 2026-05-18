# Regression: S1 (truthy? elision via TypeInfer) made `while True:`
# emit a bare `true ->` clause inside the while-emitter's `cond`,
# colliding with the existing `true -> <fallback>` clause and
# tripping Elixir's `this clause in cond will always match` warning
# (elevated to a compile error in the eval harness). Fix: keep the
# `truthy?` wrap when the test is a Constant boolean — the wrap
# stays opaque to the compile-time clause-shadowing analysis.

n = 10
total = 0
while True:
    total = total + 1
    if total >= n:
        break

print(total)  # 10
