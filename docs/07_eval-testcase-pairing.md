# Eval: pair `seed_sft` solutions with `seed_testcase` inputs in Elixir-only data path

## Context

The behavioral-equivalence harness lands behaviorally-equivalent verdicts on only ~1.8% of `synthetic_sft` samples because the dataset's solutions are competitive-programming scripts that read from stdin we don't provide. With `/dev/null` on stdin, 60%+ raise `EOFError` before any meaningful behavior runs.

**Investigation outcome:**

- ✅ **`seed_sft` ⟷ `seed_testcase` IS joinable** by `question_id`. Schema (confirmed via the dataset's README + a live pyarrow probe of seed_sft shard 0):
  - `seed_sft` columns: `question_id, question, starter_code, response, code, verified, is_passed`
  - `seed_testcase` columns: `question_id, question, starter_code, inputs, outputs, is_synthesized, test_case_type, func_name, class_name`
  - Shard 0 of seed_sft: 29,583 rows / 1,880 unique question_ids → ~16 solutions per question.
  - `is_passed=True` rate: **2,948 / 29,583 ≈ 10%** in shard 0.

- ❌ **`synthetic_sft` has NO `question_id`** field. Not directly joinable to `synthetic_rl_testcase`. Out of scope.

- ⚠️ **Testcase shards are huge** (~5 GB each; 30 shards × ~5 GB ≈ 150 GB total). Per-shard processing is essential.

## Resolved decisions (post-grill)

1. **Hard-coded to `seed_sft` + `seed_testcase`.** No `--dataset` / `--name` / `--split` / `--field` / `--cache` / `--no-cache` / `--testcase-name` switches. Constants in `Eval.Dataset`: `microsoft/rStar-Coder` / `seed_sft` / `seed_testcase` / `train`, source column = `code`.

2. **Only `is_passed=True` solutions are evaluated.** Hard filter, no flag. Running against `is_passed=False` is pure noise.

3. **`--limit N` semantics: N (qid, solution) records** after dedup. One sample = one solution + its full testcase set (~16 testcase runs).

4. **All-Elixir data ingestion path.** Parquet shards downloaded via HTTPS and read via the `:explorer` Hex package (Polars under the hood). No Python helper script for data loading — the previous `priv/python/dataset_stream.py` is removed entirely. Python is *only* used for what fundamentally requires it: short-lived `python3.14` subprocesses for (a) AST extraction inside `Pylixir.python_ast/1` (called by `Pylixir.transpile/1` via `priv/python/serialize.py` — internal to Pylixir, not eval-specific), and (b) sample execution inside `Eval.Execute.run_python` (the per-(source, stdin) behavioral check). Everything else — dataset download, parquet read, filtering, joining, dedup, comparison, reporting — is Elixir.

5. **Asymmetric normalization on the dataset side, strict on the Pylixir side:**
   - Python actual ⟷ dataset `expected`: trim trailing newlines on both sides before comparing (dataset noise tolerated).
   - Elixir actual ⟷ Python actual: strict byte-equal modulo `\r\n → \n` (real Pylixir bugs surface).

6. **`--testcase-shards K` knob, default K=1.** All seed_sft shards always read (full sft is small after column projection — ~50 MB compressed × 20 shards).

7. **Run ALL testcases per sample.** Per-sample bucket = worst-of across testcases (severity: `:elixir_runtime_error` / `:elixir_timeout` > `:output_mismatch` > `:python_disagrees_expected` > `:ok`).

8. **4-way per-testcase classification:**

   | python_matches_expected | elixir_matches_python | Per-testcase bucket                                                  |
   |-------------------------|-----------------------|----------------------------------------------------------------------|
   | ✓                       | ✓                     | `:ok`                                                                |
   | ✓                       | ✗                     | `{:output_mismatch, fp}` (Pylixir bug)                               |
   | ✗                       | ✓                     | `{:python_disagrees_expected, fp}` (sample broken; Pylixir faithful) |
   | ✗                       | ✗                     | `{:output_mismatch, fp}` (Elixir-vs-Python diff dominates)           |

9. **Keep the Python double-run** (determinism check) for testcase mode.

10. **Compile once per sample, execute per testcase** inside one `CompilePool` slot.

11. **Per-failing-testcase artifacts + per-sample summary.md** under `mismatches/<fp>/`.

12. **Sample IDs are `<qid>--<sha8>`** (stable across runs; sha8 = first 8 hex of sha256(source)).

13. **Dedup by `(qid, sha256(source))`** inside `Eval.Corpus`. Cross-qid duplicates (same source, different testcases) kept — different evaluation work.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Elixir (the whole harness)                               │
│                                                          │
│   Eval.Dataset                                           │
│     ├─ download_shard/2  (HTTPS via :req → cache/parquet)│
│     └─ read_shard/2      (parquet via :explorer)         │
│              │                                           │
│              ▼                                           │
│   Eval.Corpus.build/1                                    │
│     ├─ scan seed_sft (proj: qid, code, is_passed)        │
│     ├─ scan up-to-K seed_testcase shards (proj +         │
│     │   filter by passing qids)                          │
│     ├─ dedup solutions by (qid, sha256(source))          │
│     └─ yield lazy stream of %{id, source, testcases}     │
│              │                                           │
│              ▼                                           │
│   Eval.process → Task.async_stream → Eval.attempt/2      │
│              │                                           │
│              ▼                                           │
│   Pylixir.transpile  →  Compile.check_and_execute_       │
│     │                    testcases (one CompilePool slot)│
│     │                          │                         │
│     ▼                          ├─ run_elixir (Task +     │
│   python_ast (serialize.py)    │   CaptureIO + stdin)    │
│     │                          │                         │
│     │                          ▼                         │
│     │                  Eval.PythonCache.lookup           │
│     │                          │                         │
│     │                          ▼ (miss)                  │
│     │                  Eval.Execute.run_python           │
│     │                          │                         │
└─────┼──────────────────────────┼─────────────────────────┘
      │                          │
      ▼                          ▼
┌─────────────────────┐  ┌─────────────────────┐
│ python3.14          │  │ python3.14          │
│ (AST extraction —   │  │ (sample execution — │
│  one subprocess per │  │  one subprocess per │
│  unique source)     │  │  (source, stdin))   │
│ priv/python/        │  │                     │
│  serialize.py       │  │                     │
└─────────────────────┘  └─────────────────────┘
   ↑ internal to Pylixir,    ↑ direct from
     not eval-specific         Eval.Execute
```

## Per-sample pipeline (testcase mode)

```
Eval.Corpus yields  %{id: "<qid>--<sha8>", source: "...", testcases: [...]}
   ↓
Pylixir.transpile(source) ── fails → existing :unsupported / :parse_error / :internal
   ↓
Compile.check_and_execute_testcases(elixir_source, testcases, elixir_timeout_ms)
   ↓ inside one CompilePool slot:
   ↓   1. compile once → diagnostics
   ↓   2. for each testcase {stdin, expected}:
   ↓        py_entry = PythonCache.lookup(sha(source <> "\0" <> stdin))
   ↓                   ↳ miss → Execute.run_python(source, stdin: stdin) ×2 → cache
   ↓        if py_entry.outcome != ok: per_tc << {:python_*, ...}, continue
   ↓        py_matches_expected? = lenient_eq(py.stdout, expected)
   ↓        ex_result = Execute.run_elixir(module, elixir_timeout, stdin: stdin)
   ↓        case ex_result:
   ↓          :raised  → per_tc << :elixir_runtime_error
   ↓          :timeout → per_tc << :elixir_timeout
   ↓          :ok      → ex_matches_py? = strict_eq(ex.stdout, py.stdout)
   ↓                     per_tc << classify4(py_matches_expected?, ex_matches_py?)
   ↓   3. delete + purge module (try/after)
   ↓   4. sample_bucket = worst_of(per_tc)
```

## Bucket changes

Reused: `:ok`, `:ok_empty_output`, `{:output_mismatch, fp}`, `{:elixir_runtime_error, Mod}`, `:elixir_timeout`, `:python_*`, `:nondeterministic_observed`.

New: `{:python_disagrees_expected, fp}` — fingerprint = first 60 chars of first divergent line between Python actual and dataset expected.

Metadata on sample-level entries carries the full per-testcase result table for the `<NNN>.summary.md` writer.

## Module changes

### Removed

- `tools/eval/priv/python/dataset_stream.py` — entirely. No more Python helper script.
- `tools/eval/lib/eval/stream.ex` — replaced.

### New: `tools/eval/lib/eval/dataset.ex`

Owns parquet ingestion. All HF-specific knowledge lives here.

- `@dataset_repo "microsoft/rStar-Coder"` and explicit shard counts as module attributes.
- `cache_dir/0` → `tools/eval/cache/parquet/`.
- `download_shard(:seed_sft | :seed_testcase, idx) :: {:ok, path} | {:error, _}` — fetches `https://huggingface.co/datasets/microsoft/rStar-Coder/resolve/main/<config>/data-<NNNNN>-of-<NNNNN>.parquet` via `:req` if not already cached on disk. Streams the response body into `<path>.partial` (chunked, with a per-shard progress line printed every ~5% or 5 seconds), then atomic-renames to `<path>` only on a successful complete read. Failed `.partial` files are unlinked on the next invocation and retried from scratch — no resume logic.
- `read_sft_shard(idx, cols) :: Explorer.DataFrame.t` — `Explorer.DataFrame.from_parquet!/2` with column projection.
- `read_testcase_shard(idx, qid_filter) :: Explorer.DataFrame.t` — lazy load + Polars filter pushdown on `question_id ∈ qid_filter`, materialize only matching rows.

### New: `tools/eval/lib/eval/corpus.ex`

Builds the joined+deduped corpus from `Eval.Dataset`'s outputs. Public surface: `build(opts) :: Enumerable.t`.

**Build phases (cold path):**

1. **Pass over all seed_sft shards** (projection: `question_id, code, is_passed`). Filter `is_passed=True`. Collect into `solutions_by_qid :: %{qid => [%{sha, source}]}` — dedup by `(qid, sha256(source))` happens here using a per-qid MapSet.
2. **Pass over up-to-K seed_testcase shards** (filter pushdown by `qid ∈ keys(solutions_by_qid)`, projection: `question_id, inputs, outputs`). Build `testcases_by_qid :: %{qid => [%{stdin, expected}]}`.
3. **Serialize** the maps + a header `%{shards_loaded: K, parquet_mtimes: %{...}}` to `cache/corpus_v1.term.gz` (gzip-compressed `:erlang.term_to_binary/2`). Compressed size ~500 MB for K=1; load time ~5-10 s (vs 30 s-2 min for a full Polars rebuild).
4. **Yield lazy enumerable**: for each qid in `solutions_by_qid` that also exists in `testcases_by_qid`, for each `{sha, source}` in its solution list, yield `%{id: "<qid>--<sha8>", source: source, testcases: testcases_by_qid[qid]}`. Qids in `solutions_by_qid` that are *not* in `testcases_by_qid` (because their testcase shard wasn't loaded under the current `--testcase-shards K`) are dropped before yielding, and each dropped solution is counted in a separate `testcase_shard_missing` total surfaced in the report.

**Warm path (corpus cache hit):** `cache/corpus_v1.term.gz` exists, its header's `shards_loaded == K`, and no underlying parquet file has a newer mtime than the corpus cache. Then: gunzip + `:erlang.binary_to_term/1` to restore the two maps. Skip phases 1-3. Yield as in phase 4.

**Invalidation triggers a rebuild:** `--testcase-shards K` changed; any parquet shard refreshed; corpus cache absent or corrupt. Old cache file unlinked, new one written atomically (`.partial` rename pattern).

Memory budget: solutions_by_qid ≈ 6K × ~3 KB ≈ 20 MB. testcases_by_qid ≈ 1.9K × ~1.5 MB ≈ 3 GB (K=1). Linear in K.

### Modified: `tools/eval/lib/eval.ex`

Replace the `Eval.Stream.stream/1` call in `run/1` with `Eval.Corpus.build/1`. Threading of opts unchanged (minus the removed `:execute` opt).

`attempt/2` is rewritten as a single testcase-mode path. **Deletions:**
- `attempt_compile_only/1` (only existed for `--no-execute`).
- `attempt_with_execution/2`'s non-testcase branch (only existed for stdin-less synthetic_sft samples).
- The `:execute` opt threading throughout.
- The single-output `outcome` shapes returned to `Bucket.classify` (replaced by `{:executed_testcases, ...}`).

### Modified: `tools/eval/lib/eval/execute.ex`

- `run_python(source, opts)` gains `:stdin` opt. When present, write stdin content to a sibling tmp file; shell redirect `... < tmp.stdin`. Both tmp files cleaned in `try/after`.
- `run_elixir(module, timeout_ms, opts)` gains `:stdin` opt. Uses `ExUnit.CaptureIO.capture_io(stdin_string, fn -> ... end)` — proven in `test/pylixir/runtime_helpers_test.exs:10`.
- New `compare_lenient(actual, expected)` for the Python↔expected leg (trim trailing `\n`s + `\r\n → \n` then byte-equal). Existing `compare_outputs/2` stays for the strict Python↔Elixir leg.

### Modified: `tools/eval/lib/eval/compile.ex`

- Add `check_and_execute_testcases(source, testcases, elixir_timeout_ms, on_testcase) :: result` where `on_testcase` is invoked per testcase with the loaded module and the testcase struct, returning a per-testcase classification.
- Slot lifetime: compile → iterate testcases → delete + purge in `try/after`.
- **Delete** `check/1` and `check_and_execute/2` — both only existed to support `--no-execute` and the single-output path.

### Modified: `tools/eval/lib/eval/bucket.ex`

- New `python_failure` variant `:disagrees_expected`.
- New `bucket_key()` variant `{:python_disagrees_expected, fp}`.
- New `outcome()` variant `{:executed_testcases, diagnostics, [tc_outcome]}`.
- New `classify/2` clause implementing worst-of aggregation.
- New `slug/1` clause for `:python_disagrees_expected`.
- **Delete** the `outcome` variants for the single-output Elixir-only path: `{:transpile_ok, src, {:execute_ok, ...}}`, `{:transpile_ok, src, {:execute_raised, ...}}`, `{:transpile_ok, src, {:execute_timeout, ...}}`, `{:transpile_ok, src, {:compile_ok, ...}}` (this last one only fires from `--no-execute`). Plus the matching `classify/2` clauses.

### Modified: `tools/eval/lib/eval/python_cache.ex`

- Replace `key/1` with `key/2(source, stdin) :: sha256(source <> "\0" <> stdin)`. Single-arg key dies with the synthetic_sft / `--no-execute` path.
- On startup: if `cache/python.jsonl` exists and has any line missing the new schema fields (or just unconditionally), delete it. Log: `"removing cache/python.jsonl from previous schema; rebuilding from scratch"`.
- Same one-time cleanup pass also removes the legacy dataset-cache files (`cache/microsoft_rStar-Coder--*.jsonl`) since the new code path doesn't consume them. Log once per file.

### Modified: `tools/eval/lib/eval/report.ex`

- Mismatch dir layout for `{:output_mismatch, _}` and `{:python_disagrees_expected, _}`:
  ```
  mismatches/<fp>/
  ├── <NNN>.py
  ├── <NNN>.ex
  ├── <NNN>.summary.md          (per-sample testcase pass/fail table)
  ├── <NNN>.testcase_<idx>.stdin.txt
  ├── <NNN>.testcase_<idx>.expected.txt
  ├── <NNN>.testcase_<idx>.python.txt
  ├── <NNN>.testcase_<idx>.elixir.txt   (omitted when Elixir didn't run)
  └── <NNN>.testcase_<idx>.diff
  ```
- `summary.json` adds `totals.testcases_run`, `totals.testcases_passed`, `totals.testcase_shard_missing`. Schema bump to `schema_version: 3`.
- `summary.md` headline includes a hint line when `testcase_shard_missing > 0`: `"X passing solutions have testcases in seed_testcase shards not loaded (current: K; total available: 30). Pass --testcase-shards K' to include more."`

### Modified: `tools/eval/lib/mix/tasks/eval.run.ex`

Drop switches: `--dataset`, `--name`, `--split`, `--field`, `--cache`, `--no-cache`.

Add switches: `--testcase-shards K` (default 1).

Drop `--execute` / `--no-execute` as well (continuation of the same-spirit simplification: the harness has one mode now — evaluate against testcases).

Keep: `--limit`, `--skip`, `--concurrency`, `--samples-per-bucket`, `--save-ok`, `--python-timeout`, `--elixir-timeout`, `--no-python-cache`, `--rebuild-python-cache`, `--out`.

### Modified: `tools/eval/mix.exs`

Add deps:
```elixir
{:explorer, "~> 0.10"},
{:req, "~> 0.5"}
```

`:explorer` ships precompiled NIFs for common targets — no Rust toolchain needed at install time. `:req` is for the parquet download (no auth needed; rStar-Coder is public).

## Critical files

- **Removed**: `tools/eval/priv/python/dataset_stream.py`, `tools/eval/lib/eval/stream.ex`.
- **New**: `tools/eval/lib/eval/dataset.ex`, `tools/eval/lib/eval/corpus.ex`.
- **Modified**: `tools/eval/lib/eval/execute.ex`, `tools/eval/lib/eval/compile.ex`, `tools/eval/lib/eval/bucket.ex`, `tools/eval/lib/eval.ex`, `tools/eval/lib/eval/python_cache.ex`, `tools/eval/lib/eval/report.ex`, `tools/eval/lib/mix/tasks/eval.run.ex`, `tools/eval/mix.exs`.
- **Test updates** (under `tools/eval/test/`):
  - `eval_test.exs` — rewrite. Existing "golden fixtures land in :ok" test drove the now-deleted single-output path. New version: mock-corpus enumerable yielding `%{id, source, testcases}` records, asserts worst-of aggregation works end-to-end. Skip-envelope test deleted (no more `_skip` lines from the now-removed dataset_stream.py).
  - `eval/bucket_test.exs` — keep transpile-failure tests as-is (UnsupportedNodeError, PythonParseError still apply). Replace `{:compile_ok, ...}` clauses with `{:executed_testcases, ...}` clauses. Add 4-way truth-table classification tests.
  - `eval/report_test.exs` — bump `schema_version` assertion to 3. Drop `comparison_mode: :compile_only` test path (the field is gone). Add assertions for `testcase_shard_missing` and `testcases_run`/`testcases_passed` totals.
  - **New** `eval/corpus_test.exs` — unit-test `Eval.Corpus.build/1` with an injected mock `Eval.Dataset` that returns hand-crafted DataFrames. Verify dedup, join, and `testcase_shard_missing` accounting.

## Reuse references

- `test/pylixir/runtime_helpers_test.exs:10` — `capture_io("hello\n", fn -> ... end)` stdin pattern.
- `lib/pylixir/runtime_helpers.ex:1472-1494` — `py_input/0`, `py_stdin_read/0`, `py_stdin_readline/0` already swap-GL friendly.
- `test/fixtures/python/35_sys_stdin_readline.py` — stdin-driven fixture, passes golden corpus.
- `tools/eval/lib/eval/compile_pool.ex` — slot-ownership pattern.

## Concurrency & safety

- Slot held for compile + Σ(testcase Elixir runs) + purge. Worst case ~80s per sample at 16 testcases × 5 s. Realistic mean much lower.
- `capture_io` per-caller-process GL swap; concurrent `Task.async_stream` workers don't bleed stdout.
- Python tmp files (source + stdin) cleaned via `try/after`.
- Parquet downloads cached on disk; `Eval.Dataset.download_shard` is idempotent (skip if file exists).
- Memory: ~3 GB peak for K=1 testcase shard (full testcases_by_qid map). Document.

## Verification

```
# Cold cache. First invocation downloads seed_sft shards + 1 seed_testcase shard.
PYLIXIR_PYTHON=python3.14 mix eval.run --limit 20 --samples-per-bucket 5
```

Expect:
- `tools/eval/cache/parquet/seed_sft/data-00000-of-00020.parquet` (and others) populated.
- `tools/eval/cache/parquet/seed_testcase/data-00000-of-00030.parquet` populated.
- `tools/eval/cache/python.jsonl` populated.
- `summary.json` has `schema_version: 3`, `comparison_mode: "executed"`, non-zero `:ok` count substantially above the synthetic_sft 1.8% baseline.

```
# Warm cache — Python invocations only for cache misses.
mix eval.run --limit 20
```

Manual cross-check of a `:ok` sample:
```
python3.14 reports/run-*/ok/001.py < reports/run-*/ok/001.testcase_0.stdin.txt \
  | diff - reports/run-*/ok/001.testcase_0.expected.txt
```

Sanity: `mix test test/pylixir/golden_corpus_test.exs` still passes.

## Unresolved questions

None.
