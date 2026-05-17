# Regression: `try/except` raised "try/except is not supported".
# Fix: minimal Try lowering — emit Elixir's `try do ... rescue _ -> ... end`,
# ignoring the exception type and `as e` binding (Pylixir doesn't
# track exception classes). `else` chains after the body; `finally`
# becomes `after`. This is good enough for the common
# "catch ValueError/KeyError/IndexError to fall back to a default"
# patterns in competitive code. Adapted from eval-corpus failures
# (unsupported--Try, 2026-05-16).

# Bare except with a fallback.
def safe_int(s):
    try:
        return int(s)
    except:
        return -1

print(safe_int("42"))     # 42
print(safe_int("xyz"))    # -1

# except with type — type is ignored, rescues any.
def divide(a, b):
    try:
        return a // b
    except ZeroDivisionError:
        return None

print(divide(10, 3))      # 3
print(divide(10, 0))      # None

# try/except/finally — finally always runs (just print to confirm).
def with_finally(x):
    try:
        if x < 0:
            return "negative"
        return x * 2
    except:
        return "error"
    finally:
        print("finally_for", x)

print(with_finally(5))    # finally_for 5\n10
print(with_finally(-1))   # finally_for -1\nnegative

# try/except/else — else runs only when body didn't raise.
def parse_or_default(s, default):
    try:
        v = int(s)
    except:
        return default
    else:
        return v * 2

print(parse_or_default("5", 0))      # 10 (else runs)
print(parse_or_default("nope", 0))   # 0 (except runs, else skipped)
