# Regression: `type(x).__name__` raised UnsupportedNodeError because
# generic attribute access on a runtime value isn't supported. Special-
# cased the precise shape `type(x).__name__` in `Pylixir.Converter`,
# lowering to `py_type_name(x)`. Other attribute accesses on runtime
# values still raise — the special-case is narrow on purpose.

print(type(5).__name__)              # int
print(type(3.14).__name__)           # float
print(type("hi").__name__)           # str
print(type([1, 2]).__name__)         # list
print(type((1, 2)).__name__)         # tuple
print(type({1: 2}).__name__)         # dict
print(type({1, 2}).__name__)         # set
print(type(True).__name__)           # bool
print(type(None).__name__)           # NoneType

# Inside a string format.
x = 42
print(f"value={x} (type={type(x).__name__})")  # value=42 (type=int)
