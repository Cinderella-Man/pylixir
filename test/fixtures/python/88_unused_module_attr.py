# Regression: a top-level `stable = True` was promoted to
# `@var_stable`, but the program never read `stable` (only checked
# `if not supporting`, then printed). Elixir raises "module attribute
# @var_stable was set but never used", treated as a compile error.
# Fix: ModuleAnalysis now drops promoted attrs whose name is never
# referenced anywhere — they flow back into runtime_statements as
# plain Assigns at their original position. Adapted from an
# eval-corpus failure (compile_error--module_attribute_var_X_was_set_but_never_used,
# 2026-05-16).

# Referenced attr — stays as @var_THRESHOLD.
THRESHOLD = 10

# Unused attr — demoted to runtime so no compile warning.
STABLE = True
UNUSED = "ignore me"

n = 5
if n > THRESHOLD:
    print("over")
else:
    print("under")

# THRESHOLD is referenced above, so it stayed as a module attr.
# STABLE / UNUSED were dropped — no warning fires.
print("done")
