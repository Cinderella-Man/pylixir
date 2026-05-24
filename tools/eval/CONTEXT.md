# `pylixir_eval` — context

A standalone Elixir tool that measures how well **Pylixir** transpiles real Python to Elixir.
It streams a curated, pre-verified Python I/O corpus, transpiles each solution, runs the
generated Elixir, and buckets the outcome against the dataset's verified `expected` output so
the next transpiler bug to fix is obvious. This file is the orientation map; the README is the
quick-start, and the dataset-migration design lives in
[`docs/01_curated-dataset-migration-plan.md`](docs/01_curated-dataset-migration-plan.md).

---

## 1. What this is (and is NOT)

**Is:** a transpiler-quality harness. For every `(solution, testcase)` it transpiles the Python
to Elixir, compiles it, runs `py_main/0` with the testcase's `stdin`, and compares the Elixir
stdout to the dataset's `expected`. Outcomes roll up into **buckets** (a severity ladder) so a
run produces "here's where Pylixir breaks, ranked by frequency."

**Is NOT:**
- It does **not** verify Python or build datasets — that's the separate `tools/dataset` app. The
  corpus it reads is *already* verified; eval trusts `expected` as ground truth.
- It does **not** run CPython for comparison anymore. The only CPython invocation left is the
  **tracer** that captures runtime trace envelopes to guide `Pylixir.transpile/2`.

**Why it exists:** to drive Pylixir development against thousands of real programs without
hand-writing fixtures — a data-in / data-out feedback loop, not unit tests.

---

## 2. Origin & relationship to `tools/dataset`

`tools/dataset` was originally **copied from this app** (`Eval.* → Dataset.*`) and the two have
since drifted. The key dependency direction today: **eval consumes the dataset's published
output**. `tools/dataset` curates + verifies + publishes
[`CinderellaMan/rstar-coder-verified-io-deduped`](https://huggingface.co/datasets/CinderellaMan/rstar-coder-verified-io-deduped);
eval downloads that one parquet and evaluates against it. Before the migration, eval rebuilt the
corpus from raw `microsoft/rStar-Coder` shards and ran CPython itself for ground truth (a 4-way
truth table). That's all gone — see §5.

The two stay separate Mix projects so the published `pylixir` Hex package never pulls in HTTP /
parquet deps.

---

## 3. Domain language (the words that matter)

- **sample** — one corpus row: `%{id, source, testcases}`. `source` is a Python solution;
  `id` is `"<seed_qid>--<sha8>"` from the dataset.
- **testcase** — `%{stdin, expected}`. `expected` is the dataset's **verified, normalized**
  CPython output (5-run reproducibility-confirmed upstream).
- **tc_outcome** — the per-testcase verdict (`:ok`, `:ok_empty`, `:output_mismatch`,
  `:elixir_runtime_error`, `:elixir_timeout`).
- **bucket** — the per-*sample* key, the **worst-of** its testcases' outcomes (see ladder
  below). The aggregation dimension for a run.
- **example** — a `%{stdin, stdout, trace_events}` triple fed to `Pylixir.transpile/2` to guide
  transpilation. `stdout` is the dataset `expected`; `trace_events` come from the CPython tracer.
- **fingerprint** — first-divergent-line slug used to group `:output_mismatch` samples.

**Severity ladder** (`Eval.Bucket`): `:elixir_runtime_error` / `:elixir_timeout` (5) >
`:output_mismatch` (3) > `:ok` / `:ok_empty` (1). Transpile/compile failures are their own
terminal buckets (`:unsupported`, `:parse_error`, `:compile_error`, `:internal`,
`:example_conflict`).

---

## 4. Pipeline & modules

```
Eval.Corpus.build/1                      # lazy stream from cache/data.parquet
  ↳ Task.async_stream(&Eval.attempt/2)
       ↳ prewarm trace (CPython tracer → Eval.TraceCache)   [example inference only]
       ↳ Pylixir.transpile(source, examples: …)
       ↳ Eval.Compile.check_and_execute_testcases           [pooled compile + run]
            ↳ per testcase: Eval.Execute.run_elixir + classify_2way(ex vs expected)
       ↳ Eval.Bucket.classify/2  (worst-of rollup)
  ↳ accumulator (counts + first K samples per bucket)
Eval.Report.write/2                      # reports/run-<ts>/
```

### Module reference
| Module | Role |
|---|---|
| `Eval.Dataset` | `ensure_parquet/0` — download the curated `data.parquet` once (reuses a `Req` chunk streamer; download-if-absent to `cache/data.parquet`). |
| `Eval.Corpus` | `build/1` — open the parquet, lazily slice + JSON-decode `testcases` in batches, yield `%{id, source, testcases}`. Stream-only. |
| `Eval` | Orchestrator: `run/1`, `process/2`, `attempt/2`. Builds examples, transpiles, classifies 2-way, accumulates. |
| `Eval.Execute` | `run_elixir/3` (capture `py_main/0` stdout under a timeout) + `compare/2` / `normalize/1` (the canonical normalizer). |
| `Eval.Bucket` | Pure classification → `{bucket_key, metadata}`; severity ladder; `slug/1`. No I/O. |
| `Eval.Compile` / `Eval.CompilePool` | Compile transpiled Elixir in pooled module-alias slots; run all testcases inside the slot before purge. |
| `Eval.TraceCache` | Persistent (JSONL) cache of CPython tracer envelopes, keyed `key/2 = sha256(source <> 0 <> stdin)`. |
| `Eval.Report` | Writes `summary.md` / `summary.json` (schema 4) + `failures/` + `mismatches/` + `ok/`. |
| `mix eval.run` | Entry point. Also: `eval.hints` (rank buckets), `eval.show`/`eval.probe`/`eval.diag` (single-file triage), `eval.size`. |

### Key shapes
- **sample**: `%{id: String, source: String, testcases: [%{stdin: String, expected: String}]}`
- **accumulator**: `%{counts, testcase_counts, samples, totals: %{processed, transpiled, testcases_run, testcases_passed}}`

---

## 5. Design decisions & rationale (settled by review)

1. **Trust `expected`; compare 2-way.** The dataset's `expected` is verified deterministic
   CPython output, so `python_stdout ≡ expected`. Running CPython for comparison (and the old
   4-way table / determinism double-run / `python.jsonl` cache) was pure redundancy — deleted.
2. **Normalizer parity is mandatory.** `Eval.Execute.normalize/1` is a **verbatim copy** of
   `tools/dataset` `Dataset.Normalize` (CRLF→LF, per-line trailing `[ \t]` strip, drop trailing
   blank lines/newline; leading+internal spacing preserved). `expected` was produced by that
   normalizer; normalizing the Elixir side any differently would yield false `:output_mismatch`
   on solutions that print trailing whitespace.
3. **Keep example-guided transpilation.** That's how Pylixir is really used, so eval still runs
   the CPython tracer per example. Determinism is guaranteed upstream, so a single tracer run
   suffices (no double-check), and the example's `stdout` comes from `expected`.
4. **Lazy batched corpus read.** The parquet loads once into an off-heap Polars frame; rows are
   sliced + JSON-decoded one batch at a time, so `--limit N` is instant and resident BEAM memory
   stays bounded.

---

## 6. Gotchas (read before editing)

- **Project columns when reading the parquet.** `Eval.Corpus` projects `["id","source","testcases"]`;
  `testcases`/`meta` are **JSON-string** columns (not nested Arrow) — decode with `Jason`.
- **`@file` is reserved** in Elixir (don't reuse as a module attribute — use `@filename`).
- **`cache/data.parquet` is ~1.6 GB and gitignored.** First run downloads it; `rm` to refresh
  after a new dataset release. There is no auto-staleness check (deliberate).
- **The tracer is CPython.** `--no-examples` skips it entirely (fully Python-free run); without
  it, transpilation loses runtime hints. `--python-timeout` is the tracer's budget.
- A spurious `BrokenPipeError` on stdout from a tracer subprocess is harmless.

---

## 7. Running it

```bash
mix eval.run --limit 5                 # smoke (downloads data.parquet on first run)
mix eval.run --limit 10000 --concurrency 12
mix eval.run --skip 1000 --limit 500   # resume / jump ahead
#   --samples-per-bucket K  --save-ok N  --python-timeout MS  --elixir-timeout MS
#   --no-examples  --max-examples N  --out DIR
mix eval.hints                          # rank failing buckets (latest run)
mix eval.show / eval.probe / eval.diag path/to/file.py   # single-file triage
mix test                                # unit tests (hermetic; pass no_examples)
```

---

## 8. Status & open items

- **Migrated to the curated dataset** (branch `eval-curated-dataset`): ~1.6k LoC removed,
  `Eval.PythonCache` deleted, 4-way → 2-way. `mix test` green; smoke run verified.
- The single remaining CPython dependency is the tracer (example inference). If example-guided
  transpilation is ever dropped, eval becomes fully Python-free.
