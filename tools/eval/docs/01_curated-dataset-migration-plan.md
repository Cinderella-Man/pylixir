# Plan: migrate `tools/eval` to the published curated HF dataset

## Context

`tools/eval` is a maintainer-only harness that measures how well Pylixir transpiles a large
Python corpus. Today it rebuilds that corpus from **raw** `microsoft/rStar-Coder` shards
(`Eval.Dataset` downloads 20 `seed_sft` + 30 `seed_testcase` shards; `Eval.Corpus` joins,
filters `is_passed`, dedups, caches `corpus_v1.term.gz`), then per sample runs **CPython**
(twice, determinism check, cached in `python.jsonl`) for ground truth and classifies each
testcase with a **4-way truth table** (`expected` vs `python_stdout` vs `elixir_stdout`).

We have published a curated dataset, **`CinderellaMan/rstar-coder-verified-io-deduped`** — a
**single self-contained `data.parquet` (~1.6 GB)** holding everything per row: `id`, `source`
(the solution), and `testcases` (stdin + verified `expected`). Its `expected` is the
**verified, deterministic, normalized CPython output** (5-run reproducibility-confirmed, only
hash-order-stable solutions kept). Columns are JSON-string-encoded `testcases`/`meta`
(`tools/dataset/lib/dataset/emit.ex:11,49,118`), zstd-compressed.

Because `expected` is trusted ground truth, the eval's whole download+join+dedup stage and its
per-run CPython-for-comparison are redundant: `python_stdout ≡ expected` by construction, so
the 4-way table collapses to **2-way** (Elixir vs `expected`). CPython survives for exactly
one job — the trace examples that feed `Pylixir.transpile(..., examples:)` (kept, since that
reflects real Pylixir usage). Net: ~1k LoC removed.

## Resolved design decisions (grilled)

1. **Read strategy:** `DF.from_parquet!` the file once (off-heap Polars frame), then a
   `Stream.resource` that `DF.slice(offset, batch)`s + JSON-decodes **one batch at a time**
   onto the BEAM heap as the stream is pulled. Keeps `--limit N` instant and resident BEAM
   memory bounded to a batch. (Not load-all-up-front.)
2. **Download:** reuse eval's existing `Req` `stream_to_file`/`write_chunk`
   (`dataset.ex:142-217`, already handles the HF 302→CDN-LFS redirect), pointed at the one
   curated URL. No `hf` CLI dependency.
3. **Caching/staleness:** download-if-absent to `cache/data.parquet`; no mtime/ETag logic, no
   `corpus_v1.term.gz`. Refresh by `rm cache/data.parquet`. URL pinned to `resolve/main`.
4. **Normalizer:** the Elixir-vs-`expected` comparison must normalize the Elixir side
   **identically to how `expected` was produced** — copy `Dataset.Normalize` verbatim into
   `Eval.Execute` (UTF-8/latin-1 fallback → CRLF→LF → per-line trailing `[ \t]` strip → drop
   trailing blank lines/newline; leading+internal spacing preserved), applied to both sides.
   Required to avoid false `:output_mismatch` on solutions that print trailing whitespace
   (the old strict leg only worked because it compared against *un-normalized* Python).
5. **Test seam:** `Corpus.build(parquet_path: ...)` (default = `Eval.Dataset.ensure_parquet/0`);
   tests build a tiny temp `data.parquet` via `Explorer.DataFrame.new` + `DF.to_parquet!`.
   No `dataset_module`/`FakeDataset` injection.
6. **Corpus return:** stream-only (`Corpus.build/1` returns the lazy `Stream`, no `stats`
   tuple). The meaningful denominator (`processed`) is counted live in the accumulator.

## Changes by file

### Data layer
- **`lib/eval/dataset.ex`** (246 → ~40 LoC): delete the two-config shard machinery
  (`@shard_counts`, `shard_count/1`, `shard_path/2`, `read_sft_shard/2`,
  `read_testcase_shard/3`). Keep the `Req` streamer; expose `ensure_parquet/0` →
  download-if-absent to `cache/data.parquet` from
  `…/datasets/CinderellaMan/rstar-coder-verified-io-deduped/resolve/main/data.parquet`,
  returns the path.
- **`lib/eval/corpus.ex`** (355 → ~60 LoC): `build/1` opens the parquet
  (`parquet_path` opt, default `Dataset.ensure_parquet/0`), and returns a `Stream.resource`
  that slices the frame in batches, projecting `["id","source","testcases"]`, JSON-decoding
  `testcases` (`[{"stdin","expected","n_stored_outputs"}]`) → `%{stdin, expected}`, yielding
  `%{id, source, testcases}` (the existing sample shape; `id` used as-is). Delete the join,
  `is_passed`, dedup, `materialise_solutions`, `--testcase-shards`, the `corpus_v1` cache +
  mtime logic, and `stats`.

### Execution / classification
- **`lib/eval.ex`**: delete `python_outcome/3`, `run_python_twice/3`, `run_and_cache_both/4`,
  `parse_python_failure/1`, `entry_to_outcome/1`, `classify_4way/4`. Add
  `classify_2way(ex_stdout, expected, stdin)` → `{:ok|:ok_empty, base}` /
  `{:output_mismatch, fp, base}`. `testcase_outcome/4` = run Elixir, classify vs `expected`.
  Simplify `prewarm_caches/3` to **trace-only**: on `TraceCache` miss, run the tracer once
  (`Pylixir.ExampleInference.run_tracer_with_stdout`) and cache the envelope (empty envelope
  on tracer failure); no determinism double-run, no `PythonCache`. `examples_from_testcases/3`
  unchanged (already uses `expected` as the example stdout). Drop `:testcase_shards`/
  `corpus_stats`; `:python_timeout_ms` now bounds only the tracer.
- **`lib/eval/execute.ex`**: delete `run_python/2`, `do_run_python/3`, `drain_port`,
  `kill_port`, `@python_env`, `python_cmd`, `compare_lenient/2`. Keep `run_elixir/3`. Replace
  `compare_outputs/2` with one `compare/2` using the copied `Dataset.Normalize` rule
  (decision 4), same `:equal | :equal_empty | {:differ, fp, summary}` shape + `diff/2`.
- **`lib/eval/bucket.ex`**: delete the Python tier — the `{:python_failed, ...}` `classify/2`
  clauses, `python_failure_bucket/2`, all `python_disagrees_expected` paths, the severity-4/2
  entries, and their `slug/1` clauses. New ladder:
  `:elixir_runtime_error`/`:elixir_timeout` (5) > `:output_mismatch` (3) > `:ok`/`:ok_empty`
  (1). Update the moduledoc truth-table.
- **`lib/eval/python_cache.ex`**: **delete**. Move its `key/2` (`sha256(source <> 0 <> stdin)`,
  used by `TraceCache`) into `TraceCache` (or a tiny shared helper).

### Surface
- **`lib/mix/tasks/eval.run.ex`**: drop `--testcase-shards`, `--no-python-cache`,
  `--rebuild-python-cache`, and `PythonCache.ensure_started`. Keep `TraceCache.ensure_started`.
  `--python-timeout` documents "tracer budget". Update moduledoc (no 4-way / determinism cache).
- **`lib/eval/report.ex`**: remove the "Python preflight buckets" section, the
  `python preflight failures`/`nondeterministic` headline rows, `python_bucket?/1`,
  `derived_totals`' `python_failed`/`nondeterministic`, `testcase_shard_hint`, the
  `python_disagrees_expected` branches (`behavior_bucket?`, `write_failure_samples`,
  `write_mismatch_samples`, `bucket_fingerprint`), and the `.python.txt` per-testcase artifact
  (keep `stdin`/`expected`/`elixir`/`diff`). Remove the `comparison_mode` field; **bump
  `schema_version` 3 → 4** (JSON shape changed). Drop `totals.testcase_shard_missing`.

### Tests (rewrite)
- **`test/eval/corpus_test.exs`**: replace `FakeDataset` with a tiny temp `data.parquet`
  (Explorer `id|source|testcases`-JSON columns); assert streamed sample shape + testcase
  decode + lazy `--limit`-style take. Drop join/dedup/`is_passed`/shard tests.
- **`test/eval_test.exs`**: the "worst-of … `:python_disagrees_expected`" test becomes a 2-way
  `:output_mismatch` case (Elixir output ≠ `expected`); drop the `testcase_shard_missing` test.
- **`test/eval/bucket_test.exs`**: drop Python-tier tests; keep transpile/compile/elixir/
  output_mismatch/ok.
- **`test/eval/report_test.exs`**: drop the two `python_disagrees_expected` tests + the
  shard-missing/python-preflight assertions; update for `schema_version: 4`, no `.python.txt`.

### Untouched / mechanical
- `compile.ex`, `compile_pool.ex`, `trace_cache.ex` (gains `key/2`). Tasks `eval.show`,
  `eval.diag`, `eval.size`, `eval.hints`: mechanical bucket-name follow-through only.
  `eval.probe` keeps its own single-file CPython run (manual triage). `mix.exs` unchanged
  (`req` still used for download). Update `tools/eval/README.md` "Data" + "Outputs" sections.

## Verification
1. `cd tools/eval && mix compile` — clean (no refs to deleted `PythonCache`/`run_python`).
2. `mix test` — rewritten unit tests green (corpus decode/lazy, 2-way classify, bucket
   ladder, report `schema_version: 4`).
3. `mix eval.run --limit 5` — auto-downloads `cache/data.parquet`, streams a few
   `%{id, source, testcases}`, writes a report.
4. `mix eval.run --limit 200` — `summary.md` shows only Behavior + Transpile/Compile sections
   (no Python section); headline equivalence % is sane; any `:output_mismatch` now isolates a
   genuine Pylixir gap (no `python_disagrees_expected` noise).
5. Trailing-whitespace sanity: a solution printing `print(*arr)` (trailing space) buckets
   `:ok` (normalizer parity), not a false `:output_mismatch`.

## Notes / risks
- **Normalizer parity** is the one behavioral subtlety — copy `Dataset.Normalize` exactly or
  trailing-whitespace solutions false-mismatch.
- **Tracer determinism**: dropping the determinism double-run is safe because the dataset only
  shipped hash-order-stable solutions (verified over 5 runs with randomized `PYTHONHASHSEED`),
  so the tracer's stdout equals `expected` regardless of seed.
- Suggested execution on a feature branch off `output_compare`.
