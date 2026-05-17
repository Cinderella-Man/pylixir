# Regression: a comp/lambda for-target named after a hoisted module-
# level literal silently lowered to `@var_<name>` (the module attr,
# not the local). Concretely `x = 99; any(x > 3 for x in [1, 2, 3,
# 4])` returned False because the genexp body's `x` was rewritten to
# 99 instead of the for-target. Fix: in `Pylixir.Converter`, check
# `name_in_scope?` BEFORE module-attribute resolution so any local
# binding (lambda param, comp for-target, for-loop target, Assign)
# shadows the module attribute, matching Python's lexical scoping.

# Outer x is 99; genexp's x is the iteration value.
x = 99
print(any(x > 3 for x in [1, 2, 3, 4]))   # True
print(all(x > 0 for x in [1, 2, 3]))      # True

# List comp same idea.
print([x * 2 for x in [10, 20]])           # [20, 40]

# Dict comp with shadowed key name.
k = "outer"
print(sorted({k: k for k in ["a", "b"]}.items()))  # [('a', 'a'), ('b', 'b')]

# Lambda param shadowing outer.
n = 100
fn = lambda n: n + 1
print(fn(5))                                # 6

# Plain for-loop shadow.
i = 999
total = 0
for i in [1, 2, 3]:
    total += i
print(total)                                # 6
