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
