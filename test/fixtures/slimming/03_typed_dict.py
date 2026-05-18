# Targets S3: typed-dict printing inlines the repr.

print({"a": 1, "b": 2})
print({"x": 10})
print({})

d = {"name": "alice", "city": "boston"}
print(d)
