# Regression: `re.DOTALL`, `re.MULTILINE`, `re.IGNORECASE` and the
# `flags=` kwarg on `re.sub` / `re.findall` / etc. were unsupported —
# `re.DOTALL` raised "not a supported stdlib attribute" and the
# `flags=` kwarg fell through to a generic re.* call site that
# ignored it. Loop 3 of the eval-corpus work added flag support:
# each flag lowers to a bit (1/2/4) and the runtime helper
# `py_re_with_flags/2` prepends the matching PCRE inline modifier
# (`(?s)`, `(?m)`, `(?i)`) to the pattern. Multiple flags combine
# via `|` exactly like in Python.

import re

# DOTALL: `.` matches newlines (used for matching multi-line HTML/XML
# blocks). Without DOTALL the `.*?` inside `<!--...-->` would stop
# at the first newline.
html = "<!--first comment-->\n<!--second\nspans newline-->after"
print(re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL))   # \nafter

# IGNORECASE: case-insensitive match for findall.
print(re.findall(r'[a-z]+', "Hello WORLD Mixed", flags=re.IGNORECASE))
# ['Hello', 'WORLD', 'Mixed']

# MULTILINE: `^` matches at every line start, not just string start.
print(re.findall(r'^\w+', "alpha\nbeta\ngamma", flags=re.MULTILINE))
# ['alpha', 'beta', 'gamma']

# Combined flags via bitwise OR.
print(re.findall(r'^[a-z]+', "Alpha\nBETA\ngamma", flags=re.MULTILINE | re.IGNORECASE))
# ['Alpha', 'BETA', 'gamma']

# Flags omitted — plain re.* still works.
print(re.sub(r'\d+', 'N', "a1 b22 c333"))     # aN bN cN
print(re.findall(r'\d+', "1 22 333"))         # ['1', '22', '333']
