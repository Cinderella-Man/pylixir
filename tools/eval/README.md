# pylixir-eval

Maintainer-only harness that runs Pylixir against large Python datasets
(starting with [`microsoft/rStar-Coder`](https://huggingface.co/datasets/microsoft/rStar-Coder))
to surface what node types and patterns the transpiler currently can't handle.

This project lives as a **sibling Mix project** under `tools/eval/` rather
than in `lib/` so the published `pylixir` Hex package stays minimal
(no streaming, no HTTP, no dataset deps).

## Prerequisites

* Pylixir's normal prereqs (Elixir 1.19+, OTP 26+, Python 3.14+).
* Hugging Face `datasets` library for streaming:

  ```bash
  pip install datasets
  ```

## Usage

From this directory:

```bash
mix deps.get
mix eval.run --limit 50 --name synthetic_sft
```

Outputs land under `reports/run-<ISO8601>/`:

* `summary.md` — human-readable per-run summary.
* `summary.json` — machine-readable counts (for diffing runs).
* `failures/<bucket-slug>/<n>.py` — first samples per failure bucket.

## Companion tasks

* `mix eval.probe path/to/file.py [--show]` — one-shot probe pipeline.
  Runs the Python file through CPython (expected stdout), transpiles
  with Pylixir, compiles the generated Elixir, invokes `py_main/0`
  with captured stdout, and diffs against CPython's output. Exits
  non-zero with a single-line diagnostic on transpile/compile/runtime
  failure. `--show` prints the generated Elixir between the compile
  and run stages.

* `mix eval.hints <report-dir> [<bucket-slug>]` — histogram the
  `hint:` lines inside a report's `failures/<bucket>/*.py` samples.
  Surfaces which fine-grained hints dominate, with the shortest
  sample path per hint (cleanest starting point for `mix eval.probe`).
  Pass a bucket slug to scope to one bucket; omit it for an all-bucket
  joint sort.

  Typical loop: `mix eval.run --limit 200` →
  `mix eval.hints <new-run> unsupported--Call` → copy a top sample
  into `/tmp/probe.py` → `mix eval.probe /tmp/probe.py --show`.

## Flags

* `--limit N` — cap samples processed (default: 100; use a high number for a full pass).
* `--concurrency K` — `Task.async_stream` concurrency (default: schedulers × 2).
* `--split NAME` — HF dataset split (default: `train`).
* `--samples-per-bucket K` — how many failing samples to copy per bucket (default: 10).
* `--out DIR` — override the report directory.

## Why a separate Mix project?

Pylixir's public surface is `Pylixir.to_source/1` and `Pylixir.transpile/1`.
Everything in this directory is dataset fetch, batching, bucketing, and
reporting — none of it belongs in a Hex package consumed by library users.
