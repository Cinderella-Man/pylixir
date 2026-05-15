# RFC §6.13: in Python, bool is a subclass of int. So isinstance(True, int)
# returns True. py_isinstance must include is_boolean in the int check.
print(isinstance(True, int))
print(isinstance(False, int))
print(isinstance(5, int))
print(isinstance(True, bool))
print(isinstance(5, bool))
print(isinstance(5.0, int))
print(isinstance(5.0, float))
