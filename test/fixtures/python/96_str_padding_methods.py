# Regression: `str.ljust(w)`, `str.rjust(w)`, `str.center(w)` (with
# optional fill char) raised "method `.X()` is not supported". Fix:
# routed to `String.pad_trailing/2,3` and `String.pad_leading/2,3`;
# `center` reuses the `py_center_pad/3` runtime helper that the
# f-string format-spec parser already uses. Adapted from common
# Python idioms.

# ljust with default space fill.
print("hi".ljust(5))            # "hi   "
print("ab".ljust(5, "*"))       # "ab***"
print("longstring".ljust(3))    # "longstring" (no truncation)

# rjust with default space fill.
print("hi".rjust(5))            # "   hi"
print("ab".rjust(5, "0"))       # "000ab"
print("longstring".rjust(3))    # "longstring"

# center with default space fill.
print(":" + "x".center(5) + ":")        # ":  x  :"
print(":" + "ab".center(7, "-") + ":")  # ":--ab---:"
print(":" + "abc".center(3, "-") + ":") # ":abc:" (no padding)
