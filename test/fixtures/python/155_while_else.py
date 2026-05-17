# Regression: Python's `while ... else:` was rejected at transpile
# time with "while/else is not supported". Loop 2 of the eval-corpus
# work added it by mirroring the for/else lowering: wrap the
# recursive `while_N` call in a try that returns `{state, broke?}`,
# bind the threaded vars from `state`, and `unless broke?, do: else_block`.
# The else block's own assignments propagate out through a sibling
# tuple-pattern bind so post-loop reads see them.
#
# Semantics check: else runs only on natural exit (cond goes false),
# NOT on `break`. Both arms validated below.

def find(haystack, target):
    i = 0
    while i < len(haystack):
        if haystack[i] == target:
            print("found at", i)
            break
        i += 1
    else:
        print("missing:", target)

find([10, 20, 30, 40], 30)   # found at 2
find([10, 20, 30, 40], 99)   # missing: 99

# else's own assignments must leak past the if-expression scope.
def classify(n):
    state = "unknown"
    i = 1
    while i <= n:
        if i * i == n:
            state = "square"
            break
        i += 1
    else:
        state = "not_square"
    return state

print(classify(16))   # square
print(classify(15))   # not_square
print(classify(1))    # square
