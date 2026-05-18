'''Church numerals (annotated variant — drives Pylixir's annotation
passthrough so `intFromChurch -> int` and `succ(x: int) -> int` let
the converter inline list-print and collapse succ's runtime branch).
Matches 162_church_numerals.py functionally; same output.'''

from itertools import repeat
from functools import reduce


def churchZero():
    return lambda f: identity


def churchSucc(cn):
    return lambda f: compose(f)(cn(f))


def churchAdd(m):
    return lambda n: lambda f: compose(m(f))(n(f))


def churchMult(m):
    return lambda n: compose(m)(n)


def churchExp(m):
    return lambda n: n(m)


def churchFromInt(n: int):
    return lambda f: (
        foldl
        (compose)
        (identity)
        (replicate(n)(f))
    )


def intFromChurch(cn) -> int:
    return cn(succ)(0)


def main():
    cThree = churchFromInt(3)
    cFour = churchFromInt(4)

    print(list(map(intFromChurch, [
        churchAdd(cThree)(cFour),
        churchMult(cThree)(cFour),
        churchExp(cFour)(cThree),
        churchExp(cThree)(cFour),
    ])))


def compose(f):
    return lambda g: lambda x: g(f(x))


def foldl(f):
    def go(acc, xs):
        return reduce(lambda a, x: f(a)(x), xs, acc)
    return lambda acc: lambda xs: go(acc, xs)


def identity(x):
    return x


def replicate(n: int):
    return lambda x: repeat(x, n)


def succ(x: int) -> int:
    return 1 + x if isinstance(x, int) else (
        chr(1 + ord(x))
    )


if __name__ == '__main__':
    main()
