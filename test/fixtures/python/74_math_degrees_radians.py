# Regression: `math.degrees(rad)` / `math.radians(deg)` raised "not a
# supported stdlib call". Fix: lowered inline as `rad * 180 / pi` and
# `deg * pi / 180` (no runtime helper needed — pure arithmetic).
# Adapted from an eval-corpus failure (unsupported--Call, 2026-05-16).
import math

# Round trip — radians → degrees → radians should be identity (within float).
print(round(math.degrees(math.pi), 5))         # 180.0
print(round(math.degrees(math.pi / 2), 5))     # 90.0
print(round(math.degrees(0), 5))                # 0.0

print(round(math.radians(180), 5))             # 3.14159
print(round(math.radians(90), 5))              # 1.5708
print(round(math.radians(0), 5))                # 0.0

# Composition with acos to get an angle from a dot product.
print(round(math.degrees(math.acos(0.5)), 5))   # 60.0
