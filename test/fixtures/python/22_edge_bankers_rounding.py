# RFC §6.14: Python's round() uses banker's rounding (half-to-even),
# NOT half-away-from-zero. Elixir's round/1 uses half-away-from-zero,
# so this MUST go through py_round.
print(round(0.5))
print(round(1.5))
print(round(2.5))
print(round(3.5))
print(round(4.5))
print(round(-0.5))
print(round(-1.5))
print(round(-2.5))

# Non-half values just round normally.
print(round(0.4))
print(round(0.6))
print(round(-0.4))
print(round(-0.6))
