# pylixir-eval

Maintainer-only harness for running Pylixir against large Python datasets
([`microsoft/rStar-Coder`](https://huggingface.co/datasets/microsoft/rStar-Coder)
by default) to surface what the transpiler can't handle yet.

Sibling Mix project so the published `pylixir` Hex package stays free of
streaming / HTTP / dataset deps.

## Setup

One-time, from this directory:

```bash
pip install datasets   # HF streaming
mix deps.get
```

Needs Elixir 1.19+, OTP 26+, Python 3.14+.

## The loop

**The point of the loop is to grow what Pylixir can do.** Every
iteration should land one of:

1. **A new feature** — make a previously-rejected Python construct
   transpile correctly (Loop examples: `while/else` lowering,
   `re.DOTALL`/`MULTILINE`/`IGNORECASE` + `flags=` kwarg,
   `from itertools import groupby`, `from functools import cmp_to_key`
   + `sorted(..., key=cmp_to_key(...))`). Each lands one stdlib
   addition, one converter clause, or one runtime helper — small
   enough to ship in one iteration.

2. **A fix for an existing feature that's silently broken** — a
   `compile_error--*` bucket means the transpiler *accepted* the
   source but emitted Elixir that won't compile. That's a silent bug
   (the user sees `:ok` from `Pylixir.transpile/1` and a crash from
   `Code.compile_quoted/1`). Either repair the lowering, or — when
   the construct is genuinely beyond Pylixir's model — convert the
   silent compile failure into a precise `UnsupportedNodeError` with
   a `hint:` that tells the user what to refactor.

**Anti-goals**: chasing hint-count for its own sake, rewriting
working lowerings, or papering over a real semantic gap with a
rejection broad enough to over-fire. Every change must be a
strict improvement: pass rate on the eval window stays flat or goes
up, golden corpus stays at 0 failures, and the new behaviour is
locked in by **both** a negative `transpile_test.exs` assertion and
a positive `test/fixtures/python/<NNN>_<slug>.py` fixture that
exercises a now-working path.

Run from `tools/eval/` (the Mix tasks live in this sibling project, not
the root). One full iteration:

```bash
# 1. Run against the dataset — first run streams from HF and caches to
#    cache/<dataset>--<name>--<split>.jsonl; subsequent runs serve from
#    cache (and extend it if --limit exceeds the cached count).
mix eval.run --limit 1000 --name synthetic_sft

# 2. Survey the failures by hint frequency. Top hint = highest-impact
#    fix. Each row shows the shortest sample path — the cleanest repro.
#    No arg → auto-pick the most recent reports/run-* directory.
mix eval.hints                              # all buckets, latest run
mix eval.hints unsupported--Call            # one bucket, latest run
mix eval.hints reports/run-<TIMESTAMP>      # explicit run dir

# 2.5. Showcase the package — see Pylixir's actual output.
#      `eval.show` is a one-file demo (no CPython needed); pair with
#      `eval.run --save-ok N` to dump N (.py, .ex) before/after pairs
#      under reports/<ts>/ok/.
mix eval.show path/to/file.py                  # full Elixir (~2k lines: runtime helpers + user code)
mix eval.show path/to/file.py --strip-runtime  # just @moduledoc + @docs + user defs + py_main
mix eval.show path/to/file.py --out f.ex       # write to disk
mix eval.show Call/4                           # short form (latest run)
mix eval.run --limit 100 --save-ok 20          # 20 OK pairs in reports/<ts>/ok/

# 3. Probe a sample end-to-end (or a hand-rolled /tmp/probe.py).
#    Runs CPython (stdin redirected from /dev/null so stdin-reading
#    samples don't hang), transpiles + compiles + invokes py_main,
#    diffs. Exits non-zero with a one-line cause on any failure
#    stage. --show prints the generated Elixir too.
mix eval.probe path/to/sample.py [--show]
mix eval.probe Call/4                  # short form: bucket / sample-N
                                       # resolved against latest run
```

### Triage rules of thumb

- **Most failure buckets are unimplemented features, not "out of scope"** —
  if a Python construct is common in competitive code, adding support
  for it is a valid loop target. Past loops added `while/else`,
  `re.DOTALL`/`flags=`, `itertools.groupby`, `functools.cmp_to_key`,
  and a minimal Python data-class lowering (single class with
  `__init__`, read-only + mutating methods, subscript-assign on self
  attrs, nested-class hoisting). Each was one to several loops.
- **`compile_error--*` buckets are still the prize.** A bucket there
  means the transpiler accepted the source but emitted broken Elixir
  — i.e. a silent bug. Fix these even when they're tiny.
- **Genuinely out of scope** for the first-pass class lowering:
  inheritance (`class B(A):`), decorators (`@dataclass`, `@property`),
  metaclasses, `@classmethod` / `@staticmethod`, instance attribute
  access from outside the class on non-instance values. These raise
  with precise hints from `Pylixir.ClassAnalysis`.
- **`compile_error--*` buckets are the prize, not the noise.** A bucket
  there means the transpiler accepted the source but emitted broken
  Elixir — i.e. a silent bug. Fix these even when they're tiny.
- When the histogram dries up to only out-of-scope buckets, switch to
  manual probing of common idioms to find more silent bugs — or pick
  a feature gap from the `unsupported--*` buckets and implement it.

### When you reach for a "reject loudly" fix — measure twice

A rejection that turns a silent compile-error into a precise
`UnsupportedNodeError` is a strict win **only** when the rejection
predicate is tight. A past loop tried to fix a single
catalan-inside-a-demoted-`while` case by rejecting "any demoted def
whose body contains a `while`" — and over-fired on 90 legit programs
of the form `from sys import stdin; def main(): while True: ...`
(`stdin` is a runtime binding, so `main` gets demoted; the `while`
inside is harmless). Pass rate dropped from 97.5% → 93.1% before
the revert.

Before adding a `raise UnsupportedNodeError`, re-run `mix eval.run`
and compare the `:ok` count. If it dropped by more than the bucket
you're fixing, the predicate is too broad — narrow it or skip.

### Fixing a silent bug — exact procedure

When a `compile_error--compile_quoted_raised` sample shows up, the
classifier only records "compile raised" — the actual diagnostic was
captured by `Code.with_diagnostics` and dropped. Recover it with:

```bash
mix eval.diag compile_quoted_raised/1
# or any sample-path form eval.probe accepts:
mix eval.diag path/to/sample.py
```

`mix eval.diag` re-transpiles, re-runs `Code.compile_quoted/1`,
collects the dropped diagnostics, and prints each error with its
line. Returns `no errors — sample compiles cleanly` if a code change
has since fixed it.

Once the root cause is known, the fix usually means rejecting the
silent construct loudly at transpile time (raise
`Pylixir.UnsupportedNodeError` with a `hint:`) rather than letting it
become broken Elixir.

After the code change, lock the new behaviour in **two** places:

1. **Negative test** in `test/pylixir/transpile_test.exs` — assert
   `UnsupportedNodeError` with the expected `hint` for each rejected
   form. Group under a `describe` block; the existing
   "tagged unsupported literals from serialize.py" block is the
   template.
2. **Positive fixture** in `test/fixtures/python/<NNN>_<slug>.py` —
   numbered one above the current max (`ls test/fixtures/python/*.py
   | sort -V | tail -1`). Pick a sample that *should* still work and
   would have been a regression — e.g. a user `def` shadowing a
   now-rejected builtin name, or a receiver-discard idiom that the
   `attribute_methods.ex` clauses still need to handle. Header comment
   names the regression (`# Regression: ...`); body prints expected
   values inline (`# 69`) so CPython vs. Pylixir diffs are obvious.
   `test/pylixir/golden_corpus_test.exs` runs every fixture through
   CPython + Pylixir and asserts byte-equal stdout — no extra wiring.

### Verify before moving on

```bash
mix test                                              # 631+ tests, golden corpus included
cd tools/eval && mix eval.run --limit 1000 --name synthetic_sft
# Confirm: `ok` count did not drop, target bucket shrank.
```

## Reports

`reports/run-<ISO8601>/` contains:

* `summary.md` — human-readable bucket counts.
* `summary.json` — machine-readable counts (for diffing runs).
* `failures/<bucket-slug>/N.py` — first 10 samples per failing bucket,
  with a comment-prefixed metadata header (`# sample id:`,
  `# bucket:`, `# metadata:` including `hint:`) above the raw Python.

## Flags (`mix eval.run`)

| flag | default | what |
| --- | --- | --- |
| `--limit N` | unbounded | stop after N samples emitted |
| `--skip N` | 0 | skip the first N samples before emitting |
| `--concurrency K` | schedulers × 2 | `Task.async_stream` parallelism |
| `--samples-per-bucket K` | 10 | how many samples to copy per failing bucket |
| `--dataset NAME` | `microsoft/rStar-Coder` | HF dataset |
| `--name CONFIG` | (none) | HF `name=` kwarg (dataset config) |
| `--split NAME` | `train` | dataset split |
| `--field NAME` | auto | explicit source column override |
| `--cache PATH` | auto-derived | override cache file location |
| `--no-cache` | off | bypass cache (always stream fresh from HF) |
| `--out DIR` | `reports/run-<ts>` | report directory override |
