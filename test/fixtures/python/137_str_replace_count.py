# Regression: `s.replace(old, new, count)` with count>1 raised
# UnsupportedNodeError ("RFC §6.23; use count=1 or omit"). Added a
# runtime helper `py_str_replace_n/4` that walks left-to-right
# replacing the first `count` occurrences. count==0 is a no-op;
# count<0 (Python's "no limit") defers to global String.replace.

print("aaaa".replace("a", "b", 2))           # bbaa
print("aaaa".replace("a", "b", 4))           # bbbb
print("aaaa".replace("a", "b", 10))          # bbbb
print("aaaa".replace("a", "b", 0))           # aaaa
print("aaaa".replace("a", "b", -1))          # bbbb

# Multi-char old.
print("abXabXab".replace("ab", "Z", 2))      # ZXZXab

# No match — unchanged.
print("xyz".replace("a", "b", 5))            # xyz

# Empty old is a Python quirk (inserts replacement at each position
# up to `count`) — not commonly used; intentionally not implemented.
# Skip from this fixture.

# Runtime count (not a literal).
n = 2
print("AAAAA".replace("A", "B", n))          # BBAAA
