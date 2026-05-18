# Negative test: mixed-type call sites poison param to `:any`, so the
# polymorphic helpers (py_str via f-string `{x}` segment) MUST stay.
# Asserts no false elimination by the slimming PRs.

def show(x):
    return f"val:{x}"

print(show(1))
print(show("hi"))
print(show([1, 2]))
