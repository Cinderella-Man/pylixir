# pylixir_dataset

Curates a clean, **deterministically-verifiable** subset of
[`microsoft/rStar-Coder`](https://huggingface.co/datasets/microsoft/rStar-Coder) and publishes it to
HuggingFace.

rStar-Coder's stored outputs are noisy (whitespace junk, multiple-valid answers, wrong solutions,
nondeterministic programs). This tool keeps only the `(solution, testcase)` pairs where a Python
solution **reproduces its output byte-for-byte across repeated runs** and that output **matches a
stored answer**, then ships one canonical solution per problem with its verified testcases.

It is pure Python-side data generation — it does not transpile and has no other dependencies on the
parent project.

## Requirements

- Elixir `~> 1.19` / OTP 28
- `python3.14` on `PATH` (the pinned interpreter — outputs are version-sensitive)
- `unshare` + `prlimit` (sandbox; Linux with unprivileged user namespaces)
- `hf` CLI + `HF_TOKEN` (only for publishing)

## Setup

```sh
mix deps.get
mix test
```

## Build a dataset

Downloads rStar-Coder shards on first run, verifies under a sandbox, writes to `out/<version>/`:

```sh
mix dataset.build --version v1
```

Common options:

```
--version VER          output dir out/<version> (default v0)
--testcase-shards K    seed_testcase shards to load (default 1)
--qid-shard i/N        process only shard i of N merge-groups (resumable, parallelizable)
--skip N / --limit N   slice the task list
--runs N               runs per testcase for the determinism check (default 5)
--testcase-cap N       max testcases per task (default 32)
--timeout-ms N         per-run wall-clock budget (default 20000)
--size-limit BYTES     drop testcases with stdin/expected over this (default 1 MB)
--concurrency N        parallel workers (default: CPU cores)
--as-bytes / --cpu-seconds   sandbox memory / CPU limits
--no-sandbox           run python unsandboxed — TRUSTED input only
```

Work is **resumable**: a `(source, stdin)` verdict cache (`cache/`) lets a restart skip completed
verification.

## Output (`out/<version>/`)

- `data.parquet` — one row per task: `id`, `source`, `solution_sha256`, `testcases` (JSON:
  `stdin` byte-exact, `expected` normalized canonical, `n_stored_outputs`), `num_testcases`, `meta`.
- `data.jsonl` — same rows, nested JSON.
- `provenance.json` — interpreter, run count, normalization rule, merge predicate, filters, timestamp.
- `dataset_card.md` — attribution + license.

## Publish

Never automatic. Needs a repo name and `HF_TOKEN`:

```sh
mix dataset.publish you/rstar-coder-verified-io --dir out/v1 --dry-run   # prints the command
mix dataset.publish you/rstar-coder-verified-io --dir out/v1             # uploads
```

## License

Output is **CC BY 4.0**, inherited from rStar-Coder (attribution + indicate-changes). Problem
statements are not redistributed — only solution source and I/O testcases.

## More

- [`CONTEXT.md`](CONTEXT.md) — architecture, modules, design rationale, gotchas.
- [`docs/01_dataset-curation-plan.md`](docs/01_dataset-curation-plan.md) — full design.
- [`docs/02_dataset-build-tasks.md`](docs/02_dataset-build-tasks.md) — build breakdown.
