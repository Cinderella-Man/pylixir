# Regression — `pow(int, int[, int])` specialisation. Before
#   * `bin_op_ast("Pow", ...)` learned `int ** int_lit_nonneg → Integer.pow`
#   * `Builtins.emit("pow", …, [bt, et])` got the same specialisation
#   * `BuiltinSignatures.return_type` got `pow → {:int}` when args are int
# this 7-line program inflated to ~400 lines because every `pow(...)`
# call routed through `py_pow` / `py_pow_mod` whose return types were
# `:any`, which made every `print(...)` wrap the call in `py_str` and
# pull the full py_str / py_repr chain.
#
# Slim expectation: zero polymorphic helpers; `Integer.pow/2` direct
# for 2-arg pow, `py_pow_mod` direct for 3-arg (no wrap), and
# `Integer.to_string/1` for the int-typed print arg.

# 2-arg pow with literal int operands → Integer.pow at compile time.
print(pow(2, 10))     # 1024
print(pow(3, 4))      # 81

# `**` operator on int literals → also Integer.pow.
print(2 ** 5)         # 32

# 3-arg pow (modular exponentiation) with int args — still routes to
# py_pow_mod at runtime, but the return type is now inferred as
# {:int} so the print's `py_str` wrap drops.
print(pow(2, 10, 1000))  # 24
print(pow(3, 7, 100))    # 87
