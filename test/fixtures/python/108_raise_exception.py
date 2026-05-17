# Regression: `raise ValueError("msg")` raised "raise is not
# supported in MVP". Fix: Raise now lowers to
# `raise(RuntimeError, "<ClassName>: <msg>")`. Pylixir doesn't model
# exception classes, so everything funnels through RuntimeError;
# the existing type-agnostic `except:` rescues any. Bare re-raise
# (`raise` inside `except:`) still raises at translation time.

# Catch a raise in try/except.
def safe_parse(s):
    try:
        if not s.isdigit():
            raise ValueError("not a number: " + s)
        return int(s) * 2
    except:
        return -1

print(safe_parse("42"))         # 84
print(safe_parse("abc"))        # -1
print(safe_parse(""))           # -1 (isdigit is False on empty)

# Raise without args.
def must_be_positive(n):
    if n < 0:
        raise ValueError
    return n

try:
    must_be_positive(-1)
except:
    print("caught")

# Re-raise inside except is rejected at translation time, but the
# common "catch + handle + log" pattern works.
def divide(a, b):
    try:
        if b == 0:
            raise ZeroDivisionError("denominator zero")
        return a // b
    except:
        print("error in divide")
        return 0

print(divide(10, 2))            # 5
print(divide(10, 0))            # error in divide \n 0
