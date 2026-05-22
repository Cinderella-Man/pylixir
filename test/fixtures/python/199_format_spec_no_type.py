# Regression: f-string format spec with width/zero-pad but NO type
# letter (`{x:02}`, `{x:5}`). Python zero-pads or space-pads numbers
# the same as `{x:02d}` / `{x:5d}`; previously only the `d`-suffixed
# forms parsed, so `{x:02}` fell through to plain str() and skipped
# padding. Adapted from an eval-corpus mismatch (seed_24489, a
# palindrome-time search that hinged on `f"{h:02}{m:02}"`).
h = 2
m = 7
print(f"{h:02}")        # 02
print(f"{m:02}")        # 07
print(f"{h:02}{m:02}")  # 0207
print(f"{123:02}")      # 123 (wider than width)
print(f"{h:5}")         # "    2" (right-aligned, space pad)
print(f"{h:02d}")       # 02 (explicit-type form still works)

# The exact palindrome-time idiom from the corpus.
for total in [140]:
    hh = total // 60
    mm = total % 60
    s = f"{hh:02}{mm:02}"
    print(s)             # 0220
    print(s == s[::-1])  # True
