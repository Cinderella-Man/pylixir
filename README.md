# pylixir

An Elixir library that converts a Python Abstract Syntax Tree (decoded JSON map)
into working Elixir source code. `Pylixir.to_source/1` is a pure function: map
in, string out. Targets Python 3.14 ASTs and Elixir 1.19 / OTP 26+ output. The
goal is **behavioural correctness, not idiomatic style** — the generated code is
designed to produce the same observable results as the Python original on
self-contained algorithmic input.

Full specification: [`docs/rfc.md`](docs/rfc.md).

## Status

Pre-alpha. See `docs/rfc.md` for scope and roadmap.
