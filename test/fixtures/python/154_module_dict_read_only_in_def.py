# Regression: `ModuleAnalysis.reject_mutated_in_top_defs!` now bans
# module-level dict mutation inside a top-level `def`. The rejection
# must NOT over-fire — read-only access from a def (constant lookup
# tables, classification maps, etc.) is a legitimate Pylixir pattern
# that lowers to `@var_<name>` and works correctly.
#
# Companion to the eval-corpus rejection at
# `lib/pylixir/module_analysis.ex:reject_mutated_in_top_defs!`; the
# matching negative-path coverage lives in
# `test/pylixir/transpile_test.exs` under "module-level dict mutated
# inside top-level def".

DIGIT_NAMES = {0: "zero", 1: "one", 2: "two", 3: "three", 4: "four",
               5: "five", 6: "six", 7: "seven", 8: "eight", 9: "nine"}

# Read-only access from a def (the rejection must permit this).
def spell(n):
    return DIGIT_NAMES[n]

# Also exercise the local-rebind escape hatch: `flags` is rebound to a
# local dict inside `count_flags`, so its subscript-assigns don't
# touch the module-level `flags` — promotion is safe.
flags = {"a": 0, "b": 0}

def count_flags(xs):
    flags = {}
    for x in xs:
        if x in flags:
            flags[x] += 1
        else:
            flags[x] = 1
    return flags

print(spell(0))                                  # zero
print(spell(7))                                  # seven
print([spell(d) for d in [1, 2, 3]])             # ['one', 'two', 'three']
print(flags)                                     # {'a': 0, 'b': 0}
print(count_flags(["a", "a", "b", "c", "a"]))    # {'a': 3, 'b': 1, 'c': 1}
print(flags)                                     # {'a': 0, 'b': 0} (unchanged)
