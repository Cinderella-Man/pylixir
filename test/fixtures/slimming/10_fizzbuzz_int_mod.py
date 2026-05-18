# Regression — int-only Mod / FloorDiv specialisation. Before the
# `bin_op_ast` clauses for "Mod" / "FloorDiv" learned the
# `int + int → Integer.mod / Integer.floor_div` specialisation, this
# 9-line fizzbuzz inflated to ~320 lines of generated Elixir because
# `i % 15` lowered unconditionally to `py_mod`, whose polymorphic
# binary-string clause dragged the entire percent-format helper
# cascade (`py_str_percent_format`, `parse_percent_*`,
# `format_percent_typed`, `apply_percent_*`, `apply_zero_pad`) plus
# transitive `py_str` and `py_repr` chains into the emit. The slim
# expectation is now zero helpers — direct `Integer.mod/2` per call
# site, static-string `IO.write` for the literal branches, and
# `Integer.to_string` for the int branch.

for i in range(1, 16):
    if i % 15 == 0:
        print("FizzBuzz")
    elif i % 3 == 0:
        print("Fizz")
    elif i % 5 == 0:
        print("Buzz")
    else:
        print(i)
