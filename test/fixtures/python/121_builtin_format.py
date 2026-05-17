# Regression: the builtin `format(value)` / `format(value, spec)` was
# emitted as a bare `format(...)` call (no such function exists in the
# generated module), causing CompileError on a wide swath of eval
# samples (binary-pad idiom `format(n, '02b')`). Routes to py_str /
# py_format_value — same surface as `"{:spec}".format(value)`.

# No-spec — equivalent to str(value).
print(format(42))                    # 42
print(format(3.14))                  # 3.14

# Binary / hex / octal padding (the common idiom from eval samples).
print(format(5, '02b'))              # 05
print(format(255, 'x'))              # ff
print(format(255, '04X'))            # 00FF
print(format(8, 'o'))                # 10

# Float precision.
print(format(3.14159, '.2f'))        # 3.14
print(format(1000.5, '10.2f'))       # "   1000.50"

# Signed / thousands.
print(format(42, '+d'))              # +42
print(format(1234567, ','))          # 1,234,567

# Alignment.
print(format("hi", '>8'))            # "      hi"
print(format("hi", '^8'))            # "   hi   "
