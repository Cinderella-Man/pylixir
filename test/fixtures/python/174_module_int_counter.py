# Regression: module-level int counter mutated via `global x; x += 1`
# was rejected as unsupported--Module. Extended the
# mutable_module_dicts machinery to cover any simple literal (int,
# float, bool, None, dict). `global` / `nonlocal` declarations are
# now no-op AST nodes. Adapted from synthetic_sft sample 1487
# (2026-05-18).
time = 0

def step():
    global time
    time += 1

step()
step()
step()
print(time)              # 3

# Mixed initial value, AugAssign + plain Assign.
score = 100

def add(n):
    global score
    score += n

def reset():
    global score
    score = 0

add(10)
add(20)
print(score)             # 130
reset()
print(score)             # 0
