# Regression: two bugs in If state-tuple threading conspired to break
# any non-trivial if/else with branch-only assigns:
#
#   1. The else-branch saw bindings made in the if-branch (scope leak).
#      Fix: `convert_sibling_branches[_with_acc]/3` saves+restores
#      scopes between branches.
#
#   2. The if-branch's tail emitted refs to *every* threaded var, even
#      ones only the else-branch assigned (`{odd, valid}` where this
#      branch only bound `valid`). Fix: `state_tuple_value_with_defaults`
#      emits `nil` for names not bound in the current branch's context,
#      matching Python's "x = None on the falsy path" semantics.
#
# Adapted from an eval-corpus failure (compile_error--compile_quoted_raised,
# 2026-05-16).

# Case 1: branch-asymmetric assignments. After the if, `even_seen` is
# either True (set in the if-branch) or None (else-branch didn't set
# it).
nums = [2, 4, 6]
is_even_flag = True
if is_even_flag:
    even_seen = True
    valid = True
else:
    odd_count = 0
    for n in nums:
        odd_count += n % 2
    valid = odd_count == 0

# `valid` is bound in both branches; `even_seen` only in the if-branch;
# `odd_count` only in the else-branch. Pylixir picks the right one.
print(valid)

# Case 2: scope-isolation — two siblings each have a for-loop with
# the same local var name. After my loop-9 fix the for-target itself
# doesn't leak; this verifies the body-assigned vars (`temp`) inside
# the if-branch don't leak either when the else-branch's for-loop
# reuses the name.
flag = True
if flag:
    for x in [1, 2, 3]:
        temp = x * 2
    print(temp)
else:
    for x in [10, 20]:
        temp = x + 1
    print(temp)
