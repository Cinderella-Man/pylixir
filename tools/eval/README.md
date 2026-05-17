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

Three tasks, used in a cycle:

```bash
# 1. Run against the dataset — first run streams from HF and caches to
#    cache/<dataset>--<name>--<split>.jsonl; subsequent runs serve from
#    cache (and extend it if --limit exceeds the cached count).
mix eval.run --limit 1000 --name synthetic_sft

# 2. Survey the failures by hint frequency. Top hint = highest-impact
#    fix. Each row shows the shortest sample path — the cleanest repro.
mix eval.hints reports/run-<TIMESTAMP>            # all buckets
mix eval.hints reports/run-<TIMESTAMP> unsupported--Call   # one bucket

# 3. Probe a sample end-to-end (or a hand-rolled /tmp/probe.py).
#    Runs CPython for expected stdout, transpiles + compiles +
#    invokes py_main, diffs. Exits non-zero with a one-line cause on
#    any failure stage. --show prints the generated Elixir too.
mix eval.probe path/to/sample.py [--show]
```

When the histogram dries up to only out-of-scope buckets (`ClassDef`,
`Yield`, class-attribute reads) and there are no further cheap wins,
that's itself the signal — switch to manual probing of common idioms
to surface silent bugs.

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
