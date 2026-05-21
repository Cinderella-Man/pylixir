# Pylixir

A source-to-source compiler that turns Python programs into **self-contained
Elixir source code**. The output `defmodule TranslatedCode do … end` runs on the
BEAM without any runtime dependency on Pylixir — you can email the generated
file to someone and they can `mix run` it.

Targets Python 3.14 ASTs and Elixir 1.19 / OTP 26+. The goal is **behavioural
correctness, not idiomatic style**: the generated code is meant to produce the
same observable results as the Python original on self-contained algorithmic
input (competitive-programming style — `stdin` in, `stdout` out, no I/O beyond
that).

## Installation

```elixir
def deps do
  {:pylixir, git: "https://github.com/Cinderella-Man/pylixir"}
end
```

The transpiler shells out to a Python interpreter once per call (`python3.14` by
default; override via the `PYLIXIR_PYTHON` environment variable). The generated
Elixir does **not** need Python at runtime.

## Quick start

```elixir
elixir_source =
  Pylixir.transpile("""
  n = int(input())
  total = 0
  for i in range(n):
      total += i * i
  print(total)
  """)

# `elixir_source` is a string containing a complete Elixir module plus a
# trailing `TranslatedCode.py_main()` call. Save it to a `.exs` file and
# `mix run` it, or compile it in-process with `Code.eval_string/1`.
```

The same code via `to_source/1` if you already have a Python AST map (skips the
Python shell-out — useful in tests):

```elixir
ast = Pylixir.python_ast("print(1 + 1)")
Pylixir.to_source(ast)
```

## Public API

```elixir
Pylixir.transpile(python_source)              :: String.t()
Pylixir.transpile(python_source, opts)        :: String.t()
Pylixir.to_source(python_ast_map)             :: String.t()
Pylixir.to_source(python_ast_map, opts)       :: String.t()
Pylixir.python_ast(python_source)             :: map()         # shell-out only
Pylixir.validate_transpile(python_source, examples, runner)
                                              :: :ok | {:error, [mismatch]}
```

Supported `opts`:

* `examples: [%{stdin: String.t(), stdout: String.t()}]` — example-driven type
  inference. When supplied, Pylixir traces the Python program once per example
  to observe runtime types and uses that data to emit better-specialised Elixir
  (e.g. native `+` instead of the polymorphic `py_add` helper).

## Example-driven type inference

Static inference already does a lot — Pylixir lubs caller-side argument types
into function signatures, narrows `if isinstance(x, T):` branches, and routes
known builtins through typed clauses. But anything passing through
`input()` / `sys.stdin.*` / `sys.argv` is opaque at compile time, so the
generated code falls back to polymorphic runtime helpers (`py_add`, `py_mult`,
`py_int`, …).

Passing `examples:` makes Pylixir run the Python program under
`sys.settrace` on each supplied stdin, observe the actual runtime types of
top-level bindings and function parameters, and feed that data back into the
inference pass. Names with stable types across all examples get specialised
emission; the rest of the program is unaffected.

```elixir
src = """
def parse(s):
    return int(s)

funcs = {"parse": parse}
n = funcs["parse"](input())
print(n + 1)
"""

# Without examples: `n` is inferred as `:any` (the dict subscript hides
# `parse`'s return type), so `n + 1` lowers to `py_add(n, 1)`.
Pylixir.transpile(src)                       # contains "py_add"

# With examples: tracer observes `n: int`, `n + 1` lowers to native `+`.
Pylixir.transpile(src, examples: [%{stdin: "5\n", stdout: "6\n"}])
# does NOT contain "py_add"
```

When the trace reaches a value via `input()` directly, Pylixir also emits a
runtime **boundary guard** that raises `Pylixir.BoundaryViolationError` if a
later invocation receives a value of a different type — fail-loud rather than
silently mis-compile.

When no examples are supplied (or none of them produce useful traces),
behaviour is identical to `transpile/1`. The opt is purely additive.

## Validating a transpile

`validate_transpile/3` is a convenience that transpiles with examples then
runs each example through a caller-supplied runner, collecting every stdout
mismatch:

```elixir
runner = fn elixir_source, stdin ->
  # Caller owns process sandboxing + timeout + stdout capture.
  # Returns {:ok, stdout} or {:error, term}.
  MyRunner.run(elixir_source, stdin)
end

case Pylixir.validate_transpile(src, examples, runner) do
  :ok -> :all_good
  {:error, mismatches} -> inspect_mismatches(mismatches)
end
```

The library deliberately does **not** call `Code.eval_string` itself — the
runner contract lets callers choose their own sandboxing strategy.

## Known limitations

Pylixir is pre-alpha. Constructs that are deliberately out of scope and raise
`Pylixir.UnsupportedNodeError` at transpile time:

* `class` (Python OO is unsupported — model state as maps, behaviour as
  functions)
* generators (`yield`, `yield from`)
* `match`/`case` (PEP 634)
* user-side `raise` (the runtime helpers raise via Elixir; user-level
  `raise SomeError` doesn't lower)

Plus a few behavioural ones that surface as runtime divergence rather than
transpile errors — float `inf`/`nan` rejected at translation time, `try/except`
is type-agnostic (catches any exception and ignores the `as e` binding),
method dispatch is ducktyped (the call site is trusted to know the right
type).

The golden corpus (`test/fixtures/python/*.py`) is the operational spec for
"what Pylixir supports today" — every fixture runs under both CPython 3.14
and Pylixir and asserts the stdouts match.

## Documentation

* [`CONTEXT.md`](CONTEXT.md) — domain vocabulary (terms that appear in code,
  tests, and reviews — `assume_types`, `boundary site`, `Module attrs`, …).
* [`implementation.md`](implementation.md) — architecture tour.
* [`docs/rfc.md`](docs/rfc.md) — the original specification.
* [`docs/09_example-driven-type-inference.md`](docs/09_example-driven-type-inference.md)
  — design of the `examples:` opt.

## License

MIT. See [`LICENSE`](LICENSE).
