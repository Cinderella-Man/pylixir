# Regression: Church-numerals encoding from Rosetta Code — a stress
# test for several intersecting features:
#
#   * Mutual recursion across top-level `def`s (`churchFromInt` calls
#     `foldl`/`compose`/`identity`/`replicate`, which call back).
#   * Top-level defs used as VALUES (`lambda f: identity`,
#     `map(intFromChurch, [...])`). Pylixir emits these as
#     `&identity/1` captures from `Context.known_function_arities`.
#   * `from functools import reduce` and `from itertools import repeat`
#     — both hoisted to module-top `defp`s by `emit_hoisted_imports/2`
#     so they don't force their callers into closure-demotion.
#   * Closure-demotion walk descends into Lambda AND nested-FunctionDef
#     bodies (`def foldl(f): def go(acc, xs): ... return ...`).
#   * Module-level docstring → `@moduledoc`; per-function docstrings →
#     `@doc` (extracted by `Pylixir.Nodes.Functions.extract_docstring/1`).
#
# A regression in any of these blows the sample's compile or output.
'''Church numerals'''

from itertools import repeat
from functools import reduce


# ----- CHURCH ENCODINGS OF NUMERALS AND OPERATIONS ------

def churchZero():
    '''The identity function.
       No applications of any supplied f
       to its argument.
    '''
    return lambda f: identity


def churchSucc(cn):
    '''The successor of a given
       Church numeral. One additional
       application of f. Equivalent to
       the arithmetic addition of one.
    '''
    return lambda f: compose(f)(cn(f))


def churchAdd(m):
    '''The arithmetic sum of two Church numerals.'''
    return lambda n: lambda f: compose(m(f))(n(f))


def churchMult(m):
    '''The arithmetic product of two Church numerals.'''
    return lambda n: compose(m)(n)


def churchExp(m):
    '''Exponentiation of Church numerals. m^n'''
    return lambda n: n(m)


def churchFromInt(n):
    '''The Church numeral equivalent of
       a given integer.
    '''
    return lambda f: (
        foldl
        (compose)
        (identity)
        (replicate(n)(f))
    )


# OR, alternatively:
def churchFromInt_(n):
    '''The Church numeral equivalent of a given
       integer, by explicit recursion.
    '''
    if 0 == n:
        return churchZero()
    else:
        return churchSucc(churchFromInt(n - 1))


def intFromChurch(cn):
    '''The integer equivalent of a
       given Church numeral.
    '''
    return cn(succ)(0)


# ------------------------- TEST -------------------------
# main :: IO ()
def main():
    'Tests'

    cThree = churchFromInt(3)
    cFour = churchFromInt(4)

    print(list(map(intFromChurch, [
        churchAdd(cThree)(cFour),
        churchMult(cThree)(cFour),
        churchExp(cFour)(cThree),
        churchExp(cThree)(cFour),
    ])))


# ------------------ GENERIC FUNCTIONS -------------------

# compose (flip (.)) :: (a -> b) -> (b -> c) -> a -> c
def compose(f):
    '''A left to right composition of two
       functions f and g'''
    return lambda g: lambda x: g(f(x))


# foldl :: (a -> b -> a) -> a -> [b] -> a
def foldl(f):
    '''Left to right reduction of a list,
       using the binary operator f, and
       starting with an initial value a.
    '''
    def go(acc, xs):
        return reduce(lambda a, x: f(a)(x), xs, acc)
    return lambda acc: lambda xs: go(acc, xs)


# identity :: a -> a
def identity(x):
    '''The identity function.'''
    return x


# replicate :: Int -> a -> [a]
def replicate(n):
    '''A list of length n in which every
       element has the value x.
    '''
    return lambda x: repeat(x, n)


# succ :: Enum a => a -> a
def succ(x):
    '''The successor of a value.
       For numeric types, (1 +).
    '''
    return 1 + x if isinstance(x, int) else (
        chr(1 + ord(x))
    )


if __name__ == '__main__':
    main()