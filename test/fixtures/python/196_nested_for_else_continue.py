# Regression: `break`/`continue` inside a NESTED loop's `else` clause
# target the OUTER loop, not the nested one (the else runs once after
# the nested loop, outside its iteration). The same-loop break/continue
# detector must descend into a nested loop's `orelse` so the outer loop
# emits its continue/break catch — otherwise the throw escapes
# uncaught. Adapted from an eval-corpus RuntimeError (seed_20821).

# Count columns where every string shares the first string's char.
strings = ["aaa", "aba", "aca"]
length = len(strings[0])
common = 0
for i in range(length):
    current_char = strings[0][i]
    for s in strings[1:]:
        if s[i] != current_char:
            break
    else:
        common += 1
        continue
    break
print(common)  # 1 (only column 0 is all-equal)

# `break` living in the nested else should break the OUTER loop.
found = -1
for i in range(5):
    for j in range(3):
        if j == 99:
            break
    else:
        found = i
        break
print(found)  # 0 (first outer iter: inner never breaks, else runs, breaks outer)

# while-loop nested else with continue targeting the outer for.
total = 0
for i in range(4):
    k = 0
    while k < 2:
        k += 1
    else:
        total += i
        continue
    total += 100
print(total)  # 0+1+2+3 = 6
