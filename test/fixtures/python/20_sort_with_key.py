people = [
    ("alice", 30),
    ("bob", 25),
    ("carol", 35),
]

by_age = sorted(people, key=lambda p: p[1])
print(by_age[0])
print(by_age[1])
print(by_age[2])

by_name_desc = sorted(people, key=lambda p: p[0], reverse=True)
print(by_name_desc[0])
