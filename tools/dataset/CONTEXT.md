# `pylixir_dataset` — context

A standalone Elixir tool that curates a **clean, deterministically-verifiable** subset of
[`microsoft/rStar-Coder`](https://huggingface.co/datasets/microsoft/rStar-Coder) and publishes it to
HuggingFace. This file is the orientation map; the full design lives in
[`docs/01_dataset-curation-plan.md`](docs/01_dataset-curation-plan.md) and the build breakdown in
[`docs/02_dataset-build-tasks.md`](docs/02_dataset-build-tasks.md).

---

## 1. What this is (and is NOT)

**Is:** a Python-side data generator. It runs CPython solutions against testcases, keeps only the
`(solution, testcase)` pairs whose output is *deterministically reproducible and matches a stored
answer*, canonicalizes the output, merges near-duplicate problems, and writes parquet + JSONL + a
dataset card.

**Is NOT:**
- It does **not transpile** and has **no dependency on `pylixir`**. It never produces or runs Elixir.
  "Verifiable" means *a Python solution reproduces its own outputs* — Elixir-matchability is a
  downstream concern of the separate `eval` app.
- It does **not** assess problem difficulty, dedup by problem text, or repair wrong answers by voting.

**Why it exists:** rStar-Coder's stored `expected` outputs are noisy (trailing-whitespace junk,
multiple-valid-answer problems, genuinely-wrong solutions, nondeterministic programs). Downstream
work needs a *trustworthy* ground-truth I/O set. This tool produces that.

---

## 2. Origin & destiny

This started life under `tools/dataset/` inside the **pylixir** monorepo, but it is a **separate
project**. Four modules were **copied and renamed** (`Eval.* → Dataset.*`) from `tools/eval` rather
than shared, so the two codebases drift independently:

| Copied from `tools/eval` | Here | Adaptation |
|---|---|---|
| `Eval.Dataset` | `Dataset.Dataset` | verbatim + `source_repo/0` |
| `Eval.Corpus` | `Dataset.Corpus` | + `grouped/1` accessor |
| `Eval.Execute` | `Dataset.Execute` | python-only; **seed unpinned**; sandbox; output cap |
| `Eval.PythonCache` | `Dataset.PythonCache` | rekeyed `(source,stdin)`; seed dim removed |

There is **no Hex/git/path dep back into pylixir**. When extracted to its own repo:
`git subtree split --prefix=tools/dataset`.

---

## 3. Domain language (the words that matter)

- **qid** — `question_id`, rStar's per-problem id (e.g. `seed_3961`). One qid ≈ one problem.
- **task / merge-group** — one or more near-duplicate qids treated as a single problem. Identified by
  the **smallest member qid** (`group_id`). rStar contains easy/hard contest variants of the same
  problem under different qids; they merge.
- **solution** — a `(sha, source)` pair: a Python program that passed rStar's own check
  (`is_passed=true`).
- **testcase** — a `(stdin, expected)` pair. After dedup it becomes a **candidate_testcase**:
  `%{stdin, expecteds: [distinct stored outputs], n_stored_outputs}`.
- **reproducible** — running a solution on a stdin **5 times** yields byte-identical output (after
  normalization). Catches unseeded RNG, wall-clock, set/dict iteration order.
- **correct** — the reproducible output equals **at least one** stored `expected` (after
  normalization). "Any-match" because a stdin can carry several stored outputs (noise / alternate-valid).
- **canonical** — the shipped `expected`: the **chosen solution's normalized output** (not the raw
  stored value). Lossy by design (exact trailing-newline state is unrecoverable).
- **verdict** — cached per `(source, stdin)`: `{:reproducible, canonical}` or
  `{:rejected, :nondeterministic | :error | :timeout | :output_exceeded}`.

---

## 4. Pipeline & modules

Data flows through six stages. `Dataset.Build.run/1` orchestrates 0→4; `Publish` is stage 5 (manual).

```
         Corpus.solutions   all seed_sft shards ──> solutions_by_qid
Stage 0  MergeGroups        fingerprint all testcase shards ──> qid → group_id
         (slice groups by --qid-shard/--skip/--limit; default = all)
Stage 1  Spill              stream all shards ──> on-disk buckets (by group, size-filtered)
         per bucket: Candidates + qid→group ──> %{group_id => group}  (regroup, dedup, cap)
Stage 2  Verify             (solution × testcase) ──> kept/dropped (5-run gate + cache)
Stage 3  Select             group ──> {:ok, result} | :drop        (one solution, early-stop)
Stage 4  Emit               [result] ──> out/<version>/{parquet,jsonl,provenance,card}
Stage 5  Publish            out dir ──> hf upload                   (never automatic)
```

Bounded memory at any scale: fingerprinting (hashes only) precedes testcase handling; testcases are
**spilled to on-disk buckets keyed by group**, then processed one bucket at a time. Peak RAM ≈ one
testcase shard (during spill) + one bucket (during processing), independent of total size — so the
**default processes the whole dataset** (hundreds of GB) with no manual sharding. `--qid-shard` is
optional, for splitting a run across machines.

### Module reference

- **`Dataset`** (`lib/dataset.ex`) — top-level. `default_python/0` → `"python3.14"` (the pinned
  interpreter; outputs are version-sensitive). ⚠️ Do not confuse with `Dataset.Dataset`.
- **`Dataset.Dataset`** — HF parquet ingestion. `source_repo/0`, `shard_count/1`
  (`seed_sft:20, seed_testcase:30`), `shard_path/2`, `download_shard/2`, `read_sft_shard/2`,
  `read_testcase_shard/3` (Polars qid pushdown). All HF-specific knowledge lives here. **Downloads via
  the `hf` CLI** (resumable, hash-verified) — a plain streaming GET silently truncates 10 GB+ LFS
  shards into corrupt parquet.
- **`Dataset.Corpus`** — join + dedup, **split into two passes** so the build can fingerprint before
  loading testcases: `solutions/1` (all `seed_sft` shards → `solutions_by_qid`) and `testcases/2`
  (all `seed_testcase` shards, qid-pushdown + optional `:size_limit` → `testcases_by_qid`). `grouped/1`
  / `build/1` combine both (tests / small fakes). Keeps `is_passed=true`, sha-dedups solutions, parses
  `inputs`/`outputs` JSON (drops function-call/non-string rows). **No on-disk corpus cache** — the full
  join is too large to serialise; resumability lives in the verdict cache. `:dataset_module` injection.
- **`Dataset.Spill`** (Stage 1) — `run/3` streams all testcase shards once and routes each
  size-filtered testcase to an on-disk bucket file keyed by `phash2(group_id, B)` (a group's testcases
  always co-locate); `read_bucket/2` loads one bucket back. Bounds RAM regardless of dataset size.
  Records are length-prefixed `term_to_binary` (arbitrary bytes round-trip).
- **`Dataset.MergeGroups`** (Stage 0) — `group/2` is pure over fingerprint maps
  `%{qid => %{sha(stdin) => MapSet<sha(expected)>}}`; `build/2` adds shard I/O. Merge predicate:
  **≥3 shared stdins AND 0 disagreements**, transitive (connected components). Only fingerprints
  *solution qids* (pushdown), holds hashes only. `@max_fanout 64` guards ultra-common-input pair blowup.
- **`Dataset.Candidates`** (Stage 1) — `build/4` regroups by merge-group: union solutions (sha-dedup),
  union testcases **deduped by stdin** (collecting distinct `expecteds` + `n_stored_outputs`),
  **curation size filter** (drop if `stdin > 1 MB` or any `expected > 1 MB`), sorted by `sha(stdin)`.
- **`Dataset.Normalize`** — `normalize/1`, `equal?/2`. utf8(latin-1 fallback) → CRLF→LF → per-line
  `[ \t]` rstrip → drop trailing blank lines/newline. **Leading + internal spacing preserved**
  (`"1 2 3" ≠ "1\n2\n3"`). Used both as the match-gate and to produce the canonical.
- **`Dataset.Execute`** — `run_python/2` → `{:ok, stdout} | {:exit, status, out} | :timeout |
  :output_exceeded`. ⚠️ `@python_env` deliberately **omits `PYTHONHASHSEED`** (load-bearing — see §6).
  Wraps the command with the sandbox prefix; enforces a relative `:output_cap` in the port drain.
- **`Dataset.Sandbox`** — `self_test!/1` (fail-closed gate), `wrap/1`, `prefix/0`, `default_prefix/1`.
  Default: `unshare --user --map-root-user --net -- prlimit --as=2147483648 --cpu=15 --`.
- **`Dataset.PythonCache`** — GenServer; ETS reads + append-only JSONL writes. `key(source, stdin)`,
  `lookup/1`, `put/2`. Resumability backbone; entries from a different python version are ignored.
- **`Dataset.Verify`** (Stage 2) — `verdict/3` (cached reproducibility), `verify_testcase/3`,
  `verify_solution/3` (returns shippable kept testcases). `@run_count 5`, `@timeout_ms 20_000`,
  output cap = `max(expected) + 1 MB`. **Perf:** `verify_testcase/3` runs **once** and gates on
  error/timeout/correctness *before* the 5-run determinism check — a wrong answer or error costs 1 run,
  not 5; only outputs that match a stored expected pay for determinism confirmation. (Mismatches aren't
  cached — a resume re-runs them, 1 run each. `verdict/3` keeps the full 5-run path for the cache-hit
  and test surface.)
- **`Dataset.Select`** (Stage 3) — `select/2`. Caps to 32, verifies solutions in **(shortest source,
  then sha)** order, **early-stops on the first that verifies ALL**, else max-count. `:verify_fun`
  injection isolates selection logic from python in tests.
- **`Dataset.Emit`** (Stage 4) — `emit/2`. One row per task; `testcases`/`meta` are **JSON-string
  columns** in parquet (Explorer nested-type avoidance), nested JSON in the JSONL mirror. Writes
  `provenance.json` + `dataset_card.md`. No problem statement shipped.
- **`Dataset.Build`** — `run/1` orchestration (testable with `:dataset_module`).
  **`Mix.Tasks.Dataset.Build`** is the argv wrapper.
- **`Dataset.Publish`** / **`Mix.Tasks.Dataset.Publish`** — `hf upload`, `--dry-run`, `HF_TOKEN`.

### Key shapes

```
solution            %{sha: String, source: String}
candidate_testcase  %{stdin: String, expecteds: [String], n_stored_outputs: pos_integer}
group (Candidates)  %{group_id, member_qids: [qid], solutions: [solution], testcases: [candidate_testcase]}
select result       %{id: "<min_qid>--<sha8>", source, solution_sha256,
                       testcases: [%{stdin, expected, n_stored_outputs}],
                       member_qids, alternate_solution_shas}
emit parquet row    id | source | solution_sha256 | testcases(JSON) | num_testcases | meta(JSON)
```

---

## 5. Design decisions & rationale (the "why", settled by review)

- **Copy, don't share.** Separate project → divergent behavior immediately (eval pins the seed, the
  curator unpins it). A shared lib would couple two repos for illusory DRY.
- **5 runs, no seeds in the conceptual model.** `PYTHONHASHSEED` is randomized by default; just *don't
  pin it* and run 5×. P(same hash seed 5×) ≈ 0. The doc never mentions seeds — only "run 5×, drop on
  any variation".
- **Normalizer is conservative & lossy.** `[ \t]`-only trailing trim recovers whitespace noise but
  never conflates structurally-different output. Canonical = solution's normalized output; the
  contract is "compare under this normalizer", recorded in `provenance.json`.
- **One solution per task, all of *its* verified testcases.** This is also the multiple-valid-answers
  resolver: ground truth is internally consistent because one program produced every shipped output.
- **Any-match correctness.** A stdin can carry conflicting stored outputs (noise); matching any one
  confirms the solution's output is a legitimate answer. `n_stored_outputs` ships as the ambiguity signal.
- **Merge near-dups (testcase agreement, not text).** Confirmed real in the data: `seed_28362 ⇄
  seed_3961` ("Toy Train" easy/hard), 11/11 shared outputs agree. Merging is **self-healing**: a wrong
  merge only costs recall (foreign testcases fail verification and drop), never integrity.
- **Curation size filter (1 MB).** rStar I/O tail is enormous (stdin to 66 MB, expected to 30 MB).
  Oversized testcases bloat the dataset and make downstream eval miserable; dropping a *testcase*
  rarely drops a *task*.
- **Relative output cap** `len(expected)+1 MB`. A fixed 256 KB cap would falsely drop ~9% of valid
  testcases (their legitimate expected exceeds it).
- **Early-stop selection + solution cap.** `is_passed=true` solutions are mostly correct, so the first
  solution that verifies all capped testcases is provably optimal — collapses ~16 candidates to ~1–2.
  Merged near-dup groups can pool hundreds of solutions, so candidates are capped (`:solution_cap`,
  default 100, shortest-first) to bound the per-task cross-product.
- **Sandbox: userns-first.** Plain `unshare -n` fails unprivileged (`Operation not permitted`);
  `--user --map-root-user --net` works. `--nproc` dropped as fork-guard (`RLIMIT_NPROC` is
  per-real-uid, system-wide → spurious failures); rely on `--as` + `--cpu` + wall-clock SIGKILL +
  output cap. **Fail-closed** via a startup self-test (sentinel + outbound-socket probe).
- **License: CC BY 4.0, public, no problem statement.** rStar-Coder is CC BY 4.0 (redistribution +
  attribution + indicate-changes). Shipping only solution source + I/O sidesteps the Codeforces/CodeChef
  problem-statement copyright the upstream card disclaims.

---

## 6. Gotchas (read before editing)

- **`Dataset` vs `Dataset.Dataset` name collision.** The top-level app module is `Dataset`; the HF
  ingestion module is `Dataset.Dataset`. `alias Dataset.Dataset` shadows the top-level one — so
  `default_python/0` (top-level) becomes unreachable. `Emit` aliases it `as: HF` for this reason.
- **Never re-pin `PYTHONHASHSEED`.** If the copied `Execute` inherits eval's `PYTHONHASHSEED=0`, set
  iteration order freezes across all 5 runs → hash-order-dependent programs look "reproducible" and
  get kept. The `set-print → dropped` test guards this.
- **`PythonCache` is a named GenServer.** `ensure_started/1` is idempotent but the **first** caller's
  `:path` wins for the VM session; tests use unique sources so verdicts don't collide.
- **Tests run real `python3.14`.** They set `PYLIXIR_DATASET_SANDBOX=""` (no untrusted code, no netns
  needed) — except the sandbox test and the e2e test, which exercise the real sandbox. The build
  pipeline is testable end-to-end via the `:dataset_module` fake.
- **Progress output goes through `Logger`** (`[corpus]`/`[merge]`/`[build]` lines). `test_helper.exs`
  uses `ExUnit.start(capture_log: true)` so a passing run is silent and logs only surface on a failing
  test; `config/config.exs` strips Logger decoration so real runs print plain lines.
- **`defmodule` inside a test body** had compile-timing surprises — define fakes at test-module scope.

---

## 7. Running it

```sh
mix deps.get
mix test                       # 66 tests; runs real python3.14, real sandbox in two tests

# Build (downloads rStar shards on first run; sandbox on by default):
mix dataset.build --version v1 --testcase-shards 1 --qid-shard 0/8 --limit 100
#   --runs N  --testcase-cap N  --timeout-ms N  --size-limit BYTES
#   --as-bytes N  --cpu-seconds N  --concurrency N  --no-sandbox (TRUSTED only)
#   --out-dir DIR  --cache-path PATH  --skip N

# Publish (manual; needs HF_TOKEN and a repo name):
mix dataset.publish you/rstar-coder-verified-io --dir out/v1 --dry-run
```

Working dirs (`cache/`, `tmp/`, `out/`) are gitignored. `cache/` holds the resumable verdict JSONL
and the corpus term cache.

---

## 8. Upstream data shape (rStar-Coder)

- `seed_sft` (20 shards): `question_id, question, starter_code, response, code, verified, is_passed`.
  We use `question_id, code, is_passed`; **`question` is intentionally never shipped**.
- `seed_testcase` (30 shards, ~5 GB each): `question_id, question, starter_code, inputs, outputs,
  is_synthesized, test_case_type, func_name, class_name`. `inputs`/`outputs` are JSON-encoded **lists
  of strings** (index-matched), all of a qid's testcases packed per row.
- qid is 1:1 with `question` text (no exact-text duplicate problems); near-dups surface only via
  **testcase-output agreement** (hence Stage 0's signal).
- I/O sizes are heavy-tailed: stdin p50 158 B / p99 8 MB / max 66 MB; expected p50 12 B / p99 3.9 MB /
  max 30 MB. Drives the 1 MB curation filter and the "hashes-only" Stage-0 design.

---

## 9. Status & open items

**T1–T14 complete — 66 tests, 0 failures, no warnings.** Both the per-stage units and the
sandbox/e2e/contract tests pass.

Open (need real data / external input):
1. **HF repo name** (only for a real publish).
2. A genuine `mix dataset.build` over downloaded shards (sandbox on) to confirm the tunable cpu/wall/mem
   defaults by timing.
3. **Single-pass optimization (future):** the build reads all testcase shards twice (once for
   fingerprints, once to spill). They could be fused into one pass. Not done — correctness first; the
   two passes are sequential disk reads.
4. **Emit holds all results in RAM** to write one parquet. The curated *output* is far smaller than the
   input (verified subset, ≤32 testcases/task), so this is fine in practice; per-bucket parquet output
   would remove even that bound if ever needed.
