# Regression: `import json` raised unsupported--Import. Added a json
# stdlib backed by OTP-28 `:json` for decode + a custom encoder
# (Erlang's :json.encode doesn't handle Elixir tuples / MapSets and
# disagrees with Python on a few escape edges). Adapted from
# synthetic_sft sample 1559 (2026-05-18).
import json

# loads round-trip.
s = '{"name": "Alice", "age": 30, "tags": ["admin", "user"]}'
d = json.loads(s)
print(d["name"])         # Alice
print(d["age"])          # 30
print(d["tags"][0])      # admin

# Nested + null.
nested = json.loads('{"outer": {"inner": [1, 2, null]}}')
print(nested["outer"]["inner"])  # [1, 2, None]

# dumps — basic.
out = json.dumps({"a": 1, "b": [1, 2, 3], "c": None})
print(out)               # {"a": 1, "b": [1, 2, 3], "c": null} (Python's default has spaces)

# dumps — indented.
pretty = json.dumps({"x": 1, "y": 2}, indent=2)
print(pretty)

# Booleans + escaped characters.
print(json.dumps([True, False, "with \"quotes\" and a\nnewline"]))
