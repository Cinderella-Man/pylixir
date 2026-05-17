# Regression: `str.partition(sep)` / `str.rpartition(sep)` raised
# "method `.partition()` is not supported". Fix: added two runtime
# helpers backed by `:binary.split/3`. Returns Python's 3-tuple shape
# `(before, sep, after)`; when sep isn't found, partition gives
# `(string, "", "")` and rpartition gives `("", "", string)`.

# Common use: split a key:value line.
a, sep, b = "name=alice".partition("=")
print(a)              # name
print(sep)            # =
print(b)              # alice

# sep not found.
a, sep, b = "noseparator".partition("=")
print(a)              # noseparator
print(sep)            # (empty)
print(b)              # (empty)

# rpartition splits at the LAST occurrence.
a, sep, b = "a-b-c-d".rpartition("-")
print(a)              # a-b-c
print(sep)            # -
print(b)              # d

# rpartition not found.
a, sep, b = "noseparator".rpartition("=")
print(a)              # (empty)
print(sep)            # (empty)
print(b)              # noseparator
