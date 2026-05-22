# Tasks: build `pylixir_dataset` (curator)

Source of truth for *what/why*: [`12_dataset-curation-plan.md`](12_dataset-curation-plan.md). This is
the *how/order*. Coarse — one task per module/stage; tests folded into each task's done-criteria; one
end-to-end smoke task at the end. App scaffolds at **`tools/dataset/`**, namespace **`Dataset.*`**
(copied-and-renamed from `Eval.*`; pylixir-free; lifts to its own repo later via
`git subtree split --prefix=tools/dataset`).

## Dependency order
```
T1 scaffold
 ├─ T2 Dataset.Dataset ─┐
 ├─ T3 Dataset.Corpus ──┤
 ├─ T5 Normalize        │
 ├─ T6 Sandbox ─ T4 Execute
 │                      │
 T7 MergeGroups (←T2) ──┤
 T8 Candidates (←T3,T7) ┘
 T9 Verify (←T4,T5,T8)
 T10 Select (←T9)
 T11 Emit (←T10)
 T12 Build mix task (←T11) ─ T14 e2e smoke
 T13 Publish (←T11)
```
Parallelizable after T1: **T2, T3, T5, T6**.

---

## T1 — Scaffold `tools/dataset/`  ✅ DONE
**Goal:** mix project, `Dataset.*` namespace, deps, dirs gitignored.
**Do:** deps `req`, `explorer`, `jason` (NO `:pylixir`); `cache/` + `tmp/` + `out/` gitignored.
**Done:** `mix compile` clean; `mix test` green (1 test).
**Note:** `tools/eval` has no supervision tree — `PythonCache` is started lazily via `ensure_started`
in the mix task. Mirrored: `application` is just `[extra_applications: [:logger]]`; the cache GenServer
is started in the Build task (T12), not in `Application`.

## T2 — `Dataset.Dataset` (HF parquet ingestion)  ✅ DONE  ← T1
**Goal:** copy `Eval.Dataset` → rename. Plan §Pipeline-1.
**Do:** keep repo id / configs / shard counts (`seed_sft:20, seed_testcase:30`) / URL format;
`download_shard/2`, `read_sft_shard/2`, `read_testcase_shard/3` (Polars qid pushdown).
**Done:** 5 tests — shard counts, padded `shard_path` naming, out-of-range raise, fixture-parquet read
with column projection. Added `source_repo/0` accessor (for provenance later).

## T3 — `Dataset.Corpus` (join + dedup)  ✅ DONE  ← T1
**Goal:** copy `Eval.Corpus` → rename. Plan §Pipeline-1.
**Do:** keep `:dataset_module` injection (for fakes); qid join, `is_passed=true`, `sha256(source)`
dedup, `inputs`/`outputs` JSON parse (drop non-string/function-call rows).
**Done:** 4 tests on a fake dataset module — is_passed filter, sha-dedup, JSON parse + function-call-row
skip + pushdown filter, stats, stream. Added `grouped/1` accessor returning the raw
`{solutions_by_qid, testcases_by_qid, stats}` maps (T8 regroups these by merge-group).

## T4 — `Dataset.Execute` (python runner)  ✅ DONE  ← T1, integrates T6
**Goal:** copy `Eval.Execute` → rename + adapt. Plan §Structure, §Verify-Rule1, §Sandboxing.
**Do:** **delete `{~c"PYTHONHASHSEED", ~c"0"}` from `@python_env`** (load-bearing); **no `:hashseed`
param**; prepend the `PYLIXIR_DATASET_SANDBOX` prefix (T6); **relative output-size cap** in the port
drain (SIGKILL + `:output_exceeded`); keep wall-clock SIGKILL.
**Done:** 6 tests — trivial run, stdin, non-zero exit, timeout, output-cap abort, and **12-run
hash-order variation** proving the seed is unpinned. Trimmed to the python path only (dropped eval's
`run_elixir`/`compare_*` — curator uses `Dataset.Normalize`). `:output_cap` is per-call.

## T5 — `Dataset.Normalize`  ✅ DONE  ← T1
**Goal:** the conservative normalizer (gate + canonical). Plan §Normalization.
**Do:** UTF-8 decode w/ **latin-1 fallback**; CRLF→LF; per-line trailing `[ \t]` trim; drop trailing
blank lines + final newline; preserve leading/internal spacing.
**Done:** 6 tests — trailing-space/tab trimmed; leading/internal preserved (`"1 2 3"` ≠ `"1\n2\n3"`);
CRLF→LF; trailing blanks dropped / internal kept; empty cases; invalid-UTF-8 latin-1 fallback.
`normalize/1` + `equal?/2`.

## T6 — Sandbox wrapper + startup self-test  ✅ DONE  ← T1
**Goal:** fail-closed bulk-untrusted-exec sandbox. Plan §Sandboxing.
**Do:** `PYLIXIR_DATASET_SANDBOX` env, default `unshare --user --map-root-user --net -- prlimit
--as=2147483648 --cpu=15 --`; startup self-test probe (prints sentinel **and** attempts outbound
socket); assert sentinel present **and** connect failed, else **abort**.
**Done:** 5 tests — default prefix shape, empty-disables, `wrap/1`, **real self-test passes (network
isolated)**, fail-closed on broken prefix. `prefix/0`, `enabled?/0`, `wrap/1`, `self_test!/1`.

## T7 — Stage 0: `Dataset.MergeGroups`  ✅ DONE  ← T2
**Goal:** global near-duplicate task grouping. Plan §Pipeline-0.
**Do:** scan testcase shards (qid-pushdown to **solution qids only** — partners without solutions are
irrelevant, so no 5 GB whole-shard reads); per-qid `{sha(stdin) => set(sha(expected))}` fingerprints
(hashes only); inverted index; merge iff **≥3 shared stdins AND 0 disagreements**; connected-components
transitive closure; emit `qid → group_id` (min member qid).
**Done:** 7 tests — ≥3+agree merged; one disagreement not merged; <3 shared not merged; A~B~C chains;
singletons; intersect-agreement (alternate-valid); cross-shard `build/2`. Pure `group/2` +
shard-reading `build/2`; `@max_fanout` guard against ultra-common-input pair explosion.

## T8 — Stage 1: `Dataset.Candidates`  ✅ DONE  ← T3, T7
**Goal:** per-group solution + testcase pools. Plan §Pipeline-1.
**Do:** regroup by merge-group; solution pool = union (sha-dedup); testcase pool = union **deduped by
`sha(stdin)`** (each stdin keeps distinct stored `expecteds` for any-match correctness); **curation
size filter: drop testcase if `stdin > 1 MB` or any `expected > 1 MB`**; track `n_stored_outputs`; sort
testcases by `sha(stdin)` (deterministic cap downstream).
**Done:** 5 tests — merged/sha-deduped solutions; stdin-dedup with distinct expecteds +
`n_stored_outputs`; oversized stdin/expected dropped; empty-testcase group kept; no-solution excluded.

## T9 — Stage 2: `Dataset.Verify`  ✅ DONE  ← T4, T5, T8
**Goal:** the verification gate + resumable cache. Plan §What-verified, §Pipeline-2.
**Do:** per (solution × testcase) run **5×**; **reproducible** = byte-equal after `Normalize` on all 5;
**correct** = matches **any** stored expected; relative output cap = `max(expected)+1 MB`; cache
`(source, stdin)` verdict (ETS + append-only JSONL); canonical = solution's normalized output.
**Done:** 9 tests — `sorted` kept; set-print → nondeterministic drop; unseeded random drop;
`random.seed(42)` reproducible; no-match → mismatch drop; any-of-conflicting → kept; runaway →
output_exceeded drop; ETS cache hit; `verify_solution` returns shippable kept testcases.
**Note:** `PythonCache` copy folded in here (rekeyed `(source,stdin)`, seed dim removed, value =
verdict). The 32-cap lives in **T10 Select** (it owns solution iteration), not here.

## T10 — Stage 3: `Dataset.Select`  ✅ DONE  ← T9
**Goal:** one canonical solution per group. Plan §Pipeline-3.
**Do:** cap 32; verify solutions in **(shortest source, then sha)** order, **early-stop on first 100%**;
fallback = max verified-count; ship solution + verified testcases; meta = alternates' shas + member
qids; drop group if 0 verified.
**Done:** 7 tests — early-stop proven (later solutions never verified, via call-recorder); max-count
fallback; tie-break shortest→sha; drop on 0-verified / no-testcases; result fields; cap. `:verify_fun`
injection isolates selection logic from python.

## T11 — Stage 4: `Dataset.Emit`  ✅ DONE  ← T10
**Goal:** parquet + JSONL + provenance + card. Plan §Pipeline-4, §Licensing.
**Do:** **one row per task**; cols `id` (`<min_qid>--<sol_sha8>`), `source`, `solution_sha256`,
`testcases` (JSON: `[{stdin, expected, n_stored_outputs}]`, stdin byte-exact / expected normalized),
`num_testcases`, `meta` (JSON); `Explorer.DataFrame.to_parquet/2`; JSONL mirror; `provenance.json`;
`dataset_card.md` (**CC BY 4.0**, credit `microsoft/rStar-Coder`, no problem statement); `out/<version>/`.
**Done:** 4 tests — parquet round-trips (schema + parsed testcases/meta + byte-exact stdin); JSONL
mirror parses to nested rows; provenance records runs/merge/filter/cap params; card asserts
attribution + CC BY 4.0 + "problem statements removed". JSONL uses nested JSON; parquet uses
JSON-string columns (Explorer constraint). Resolved a `Dataset` / `Dataset.Dataset` alias collision
(aliased the latter as `HF`).

## T12 — `Mix.Tasks.Dataset.Build` (+ `Dataset.Build`)  ✅ DONE  ← T11
**Goal:** wire Stages 0→4, resumable. Plan §Pipeline, §Resumability.
**Do:** core orchestration in plain `Dataset.Build.run/1` (testable with injected dataset module);
`Mix.Tasks.Dataset.Build` is a thin OptionParser wrapper (`--qid-shard i/N`, `--skip/--limit`, `--runs`,
`--testcase-cap`, `--size-limit`, `--timeout-ms`, `--as-bytes`, `--cpu-seconds`, `--concurrency`,
`--no-sandbox`, cache paths). `:counters` progress; `Task.async_stream`.
**Done:** 3 tests on a fake corpus — full build (2 tasks, readable parquet, canonical outputs);
`--limit` slices; complementary `--qid-shard {0,2}+{1,2}` partition. Starts cache + sandbox self-test;
threaded `:corpus_cache_path` for hermetic runs.

## T13 — Stage 5: `Dataset.Publish` + `Mix.Tasks.Dataset.Publish`  ✅ DONE  ← T11
**Goal:** HF upload, never auto. Plan §Pipeline-5.
**Do:** `System.cmd("hf", ["upload", repo, dir, "--repo-type", "dataset"])`; auth `HF_TOKEN`;
`--dry-run` prints the command; errors on missing dir / missing token before touching `hf`.
**Done:** 4 tests — `command/2` arg list; `command_string/2`; dry-run returns command without
executing; missing-dir error. Real upload still needs a repo name + `HF_TOKEN` (manual).

## T14 — End-to-end smoke + contract  ✅ DONE  ← T12
**Goal:** prove the whole pipeline with sandbox ON. Plan §Verification-3.
**Do:** run `Dataset.Build` on a fake slice **under the real sandbox** (incl. a near-dup merge case);
re-run every shipped row in a fresh process → assert `Normalize(stdout) == stored canonical`.
**Done:** 1 test — seed_1+seed_3 merge into one task (member_qids `[seed_1, seed_3]`, id `seed_1--…`,
3 testcases), seed_2 distinct; full build under real sandbox/self-test; contract holds for all shipped
rows. Used a fake module rather than network download (real-data slice remains a manual run).

## Status: T1–T14 ✅ all done — 66 tests, 0 failures, no warnings.

## Open (post-build, need real data / external input)
- HF **repo name** under the user's namespace (only needed for a real `mix dataset.publish`).
- **Real-data run**: T14 used a fake corpus + real python. A genuine `mix dataset.build` over downloaded
  rStar shards (sandbox on) is still a manual step — that's where tunable defaults (cpu/wall/mem) get
  confirmed by timing, and where `--testcase-shards`/`--qid-shard` scaling is exercised.
- **Scaling note:** `Build` ties MergeGroups + Corpus to the same `--testcase-shards` (default 1) for
  fingerprint/text consistency. The plan's "fingerprint all 30 shards" ideal would need decoupling
  these (fingerprints over all shards, text loaded lazily per processed group) — a future refinement.
