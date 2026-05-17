# Regression: `b"..."` bytes literal raised "bytes literal is not
# supported". Fix: serializer now decodes UTF-8 bytes literals to
# plain str (the common case — competitive code treats them as
# ASCII text). Non-UTF-8 bytes still raise via the fallback path.
# Pylixir doesn't model bytes vs str separately; this matches how
# most Python competitive code uses b-strings.

# Most common: bytes literal in length / startswith / endswith — no
# bytes-vs-str print roundtrip issue here.
print(len(b"hello"))                           # 5
print(len(b""))                                # 0
print(b"prefix_data".startswith(b"prefix"))    # True
print(b"file.txt".endswith(b".txt"))           # True

# Comparison — works because both decode to the same string.
print(b"abc" == b"abc")                        # True
print(b"abc" == b"abd")                        # False

# Note: `print(b"hello")` differs between CPython (outputs `b'hello'`)
# and Pylixir (outputs `hello`) since Pylixir collapses bytes→str.
# Also: iterating bytes via `for ch in b"...":` isn't yet supported
# (string iteration via Enum is a separate gap).
