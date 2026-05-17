# Regression: `print(-0.0)` printed `0.0` instead of `-0.0` —
# Python's `-<float-literal>` lowered to `py_sub(0, 0.0)` which
# returns IEEE-754 positive zero (the sign is lost in the subtraction).
# Fix: constant-fold `USub` on a numeric literal at codegen time
# (`-0.0` becomes the literal `-0.0` Elixir AST), preserving the
# sign bit. Same fold applies to integer literals so trivial unary
# minus expressions stay readable in the generated source.

print(-0.0)                       # -0.0
print(0.0)                        # 0.0
print(-1.5)                       # -1.5
print(-42)                        # -42
print(-(0.0))                     # -0.0 (unary on parenthesized literal)

# Arithmetic with negative zero — Python's behaviour.
print(0.0 + -0.0)                 # 0.0
print(-0.0 - 0.0)                 # -0.0
print(-0.0 == 0.0)                # True
