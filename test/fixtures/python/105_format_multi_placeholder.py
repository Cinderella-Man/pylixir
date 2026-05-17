# Regression: `.format()` previously only supported single-placeholder
# templates (`{}`, `{0}`, `{:.Nf}`). Multi-placeholder, indexed-reuse,
# and keyword-arg templates raised "only single-placeholder forms
# supported". Fix: rewrote the format dispatcher to tokenize the
# template into text + placeholder segments, then emit a `<>` chain
# resolving each placeholder against args (positional `{}`/`{N}`) or
# kwargs (`{name}`). Format specs (`{:.2f}`) per placeholder still
# work — routed through `py_format_value/2` (the same runtime spec
# parser the f-string code uses). Adapted from common Python idioms.

# Multiple bare `{}` — auto-positional.
print("{} + {} = {}".format(1, 2, 3))            # 1 + 2 = 3
print("{},{}".format("a", "b"))                    # a,b

# Explicit indices — can repeat and reorder.
print("{0} {1} {0}".format("hi", "there"))         # hi there hi
print("{2}-{1}-{0}".format("a", "b", "c"))         # c-b-a

# Keyword args.
print("Hello, {name}!".format(name="World"))       # Hello, World!
print("{x} + {y} = {z}".format(x=1, y=2, z=3))     # 1 + 2 = 3

# Mix auto + indexed + spec.
print("{} {:>5} {:.2f}".format("x", "ab", 3.14159))  # "x    ab 3.14"

# Escaped braces.
print("{{literal}}".format())                      # {literal}
print("{{}} {}".format("x"))                        # {} x

# Format spec on indexed and named.
print("{0:.3f}".format(2.71828))                   # 2.718
print("{val:>5}".format(val="hi"))                 # "   hi"
