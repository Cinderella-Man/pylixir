# Regression: a user `def` whose name collides with a Python builtin
# (`hash`, `id`, `next`, `eval`, ...) used to be rejected at transpile
# time once `Pylixir.Builtins.unsupported_hint/1` started flagging the
# bare-call path. Fix: the Call router checks `context.known_functions`
# before the unsupported-builtin clause, so shadowing `def`s resolve
# to the user's function instead of raising.

def hash(x):
    return x * 31 + 7

def next(seq, default):
    return seq[0] if seq else default

def eval(expr):
    return expr.upper()

# Direct calls to each shadowed builtin.
print(hash(2))                  # 69
print(hash(10))                 # 317
print(next([1, 2, 3], -1))      # 1
print(next([], -1))             # -1
print(eval("ok"))               # OK

# Compose them — exercises in-scope resolution inside another def too.
def transform(xs):
    return [hash(x) for x in xs]

print(transform([0, 1, 2]))     # [7, 38, 69]
