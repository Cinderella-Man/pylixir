# Changelog

All notable changes to this project will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-05-16

Initial pre-alpha release.

- `Pylixir.to_source/1` converts a decoded-JSON Python AST map to
  self-contained Elixir source.
- `Pylixir.transpile/1` shells out to Python 3.14 to produce that AST
  from a Python source string.
- Supports a useful subset of Python 3 — see `docs/rfc.md` for the
  spec and `implementation.md` for the architecture tour.
- Stdlib import surface: `math`, `sys` (subset).

[Unreleased]: https://github.com/Cinderella-Man/pylixir/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Cinderella-Man/pylixir/releases/tag/v0.1.0
