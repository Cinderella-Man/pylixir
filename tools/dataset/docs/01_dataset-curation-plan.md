# Plan: `pylixir_dataset` — verified Python I/O dataset (curation only)

## Context
rStar-Coder's stored `expected` outputs are unreliable (whitespace junk, multiple-valid-answer
problems, genuinely-wrong solutions, non-determinism). This app curates a clean, **verifiable** subset
and publishes it to HuggingFace; the existing `eval` app later consumes it.

**Scope (important): this app does NOT transpile and does NOT involve pylixir.** It is purely
Python-side data generation. "Verifiable" = a Python solution *deterministically reproduces* its
testcases' stored answers. Those verifiable rows are good candidates for the *later, separate*
Python→Elixir transpilation+eval, but transpilability/Elixir-matchability is **not** assessed here.

## Project structure / dependency — STANDALONE, copy not share
This is a **completely separate project** (own repo within days). It must NOT depend on pylixir and
must NOT share a lib with `eval`. The reused pieces (`Eval.{Dataset,Corpus,Execute,PythonCache}`) are
**copied/rewritten** into the curator; the two codebases drift independently. No Hex/git/path dep back
into pylixir. ("Single source of truth" is rejected — the apps want divergent behaviour immediately,
e.g. eval keeps `PYTHONHASHSEED=0`, the curator must un-pin it; see Verify.)

Copied `Execute`: **delete the `{~c"PYTHONHASHSEED", ~c"0"}` line from `@python_env`** so the seed
randomizes (load-bearing — see Verify Rule 1). No `:hashseed` parameter is added; there is no shared
path to keep backward-compatible. Output-size cap is enforced in the port drain (see Sandboxing), not
via any env/rlimit.

## What "verified" means (keep a (solution, testcase) iff BOTH)
1. **Reproducible** — run the solution on the testcase's stdin **5 times**; keep only if output is
   byte-identical (after normalization) on every run. Any variation → drop. This single dynamic rule
   exposes *all* nondeterminism: unseeded `random`, wall-clock/time, AND set/dict iteration order.
   (Seeded `random` is genuinely deterministic so it is *kept* — it's verifiable; that pylixir can't
   reproduce MT19937 is the downstream eval's concern.) No static source scan; no permutation-rescue.
   - *Implementation note (do not "optimize" away):* the **count** of distinct runs catches per-run
     nondeterminism (random/time); leaving `PYTHONHASHSEED` **unset** (randomized per process, the
     CPython default) is what makes the runs additionally expose set/dict hash-ordering. If the copied
     runner re-pins the seed, hash-ordering becomes invisible and the `set-print → dropped` test
     silently breaks.
2. **Correct** — the deterministic output equals **at least one** of the testcase's stored `expected`
   values under the normalization below. (After stdin-dedup a stdin may carry multiple conflicting
   stored outputs — rStar noise / alternate-valid; matching *any* confirms the solution's output is a
   legitimate answer.) No majority-vote / "most-common" repair.

Canonical `expected` stored = **the chosen solution's normalized output** (not the stored dataset
output). By construction it equals some stored answer for that stdin.

## Normalization (conservative — same rule for the match-gate and the stored canonical)
UTF-8 decode with **latin-1 fallback** (no row crashes the pipeline). Then CRLF→LF, **per-line
trailing-`[ \t]`-trim** (space+tab only; `\r` already handled, `\f\v` left alone to avoid conflating
genuinely different output) + trailing newline/blank-line trim; **leading and internal spacing
preserved exactly** (so `1 2 3` ≠ `1\n2\n3`). Slightly more than eval's `lenient_normalize/1` (which
doesn't rstrip per line) → small new normalizer. The shipped canonical is therefore **lossy** (exact
trailing-newline state is unrecoverable); the dataset's contract is "compare under this published
normalizer", recorded in `provenance.normalization`. Downstream eval MUST use the same normalizer.

## Interpreter
Pin **python3.14** (parent's `@default_python`, lib/pylixir.ex:10; confirmed `3.14.5` on this box) so
canonical matches the eventual downstream target. Record the exact version in the dataset card;
outputs are version-sensitive.

## Pipeline (stages → modules)

0. **Global merge-grouping (NEW)** — `MergeGroups`: stream **all 30** `seed_testcase` shards once,
   accumulating per-qid **fingerprints only** (`{sha(stdin), sha(expected)}` — hashes, no text, so it
   fits in memory). Build a `stdin-sha → qids` inverted index. Two qids are **the same task** iff they
   share **≥3 stdins AND the stored outputs agree on every shared stdin** (zero disagreements — a
   single disagreement is evidence they differ; a coincidental trivial shared input like `"5\n"` will
   disagree on output and won't merge). Take the **transitive closure (union-find / connected
   components)** — easy/medium/hard contest variants form clusters (verified in data: `seed_28362` ⇄
   `seed_3961`, "Toy Train" easy/hard, 11/11 shared outputs agree). Emits a `qid → merge-group` map.
   Detection runs on **raw stored outputs** (pre-verification) — only a grouping heuristic;
   verification cleans the result. A wrong merge can only cost **recall** (a foreign task's testcases
   fail verification and drop), never **ground-truth integrity**. `--qid-shard i/N` operates on
   **merge-groups**, after this pass.

1. **Fetch + join + dedup** — reuse (copied) data infra: `Dataset.{download_shard/2, read_sft_shard/2,
   read_testcase_shard/3}` (HF download via Req + Polars read/pushdown) and `Corpus.build/1` (qid join,
   `is_passed=true`, sha256 solution dedup, `inputs`/`outputs` JSON parse). New `Candidates`: regroup
   by **merge-group** → `%{group => %{solutions, testcases}}`; solution pool = union of members'
   solutions (sha-deduped); testcase pool = union of members' testcases **deduped by sha(stdin)**, then
   **curation size filter: drop any testcase with `stdin > 1 MB` or `expected > 1 MB`** (cheap, from
   raw sizes; the rStar I/O tail is huge — stdin max 66 MB / p99 8 MB, expected max 30 MB / p99 3.9 MB
   — and oversized cases bloat the dataset and make the downstream Python↔Elixir eval miserable;
   dropping a testcase rarely drops a task). Merge detection in Stage 0 still fingerprints **all**
   testcases (more overlap signal); the filter only governs what's *shippable*.

2. **Verify** — new `Verify`: from the size-filtered pool, cap to **32** by stdin-sha order *before*
   verifying (don't pay to verify testcases you'll discard; shipping <32 if some fail is fine). For
   each candidate solution × capped testcase, run python3.14 5× under the sandbox; keep the testcase
   for that solution iff reproducible + correct (conservative norm). Cache per **`(source, stdin)`**
   (value = verdict: `reproducible`+canonical output, or `nondeterministic`/`error`/`timeout`) → ETS +
   append-only JSONL, resumable. No seed in the key.

3. **Select** — new `Select`: per merge-group, verify solutions in **(shortest source, then sha)**
   order and **early-stop on the first solution that verifies ALL capped testcases** (provably optimal
   — most `is_passed=true` solutions are fully correct, so this collapses ~16 solutions to ~1–2). Only
   if none hits 100% does it fall back to full cross-product and take the **max verified-testcase
   count**. Ship that solution + **all of its verified testcases** (stdin + canonical output); record
   alternates' shas + member qids in meta. Drop the group if no solution verifies ≥1 testcase.

4. **Emit** — new `Emit`: **one row per task** (merge-group), `testcases`/`meta` as **JSON-string
   columns** (avoids Explorer nested-type edges; mirrors how raw `inputs`/`outputs` are stored).
   Parquet via `Explorer.DataFrame.to_parquet/2` + JSONL mirror (same rows) + `provenance.json` +
   `dataset_card.md`, into `out/<version>/`. **No `question` (problem statement) is shipped** — see
   Licensing. Columns:

   | column | type | notes |
   |---|---|---|
   | `id` | string | `<smallest-member-qid>--<solution-sha8>` |
   | `source` | string | chosen solution's Python source |
   | `solution_sha256` | string | full sha of source |
   | `testcases` | string (JSON) | `[{"stdin", "expected", "n_stored_outputs"}, …]` |
   | `num_testcases` | int | convenience |
   | `meta` | string (JSON) | `{member_qids:[…], alternate_solution_shas:[…], source_repo, source_revision}` |

   - **`stdin` stored byte-exact** (un-normalized — it's program *input*; rStar stdins literally
     contain `\r\n`, fed as-is during verification). Only `expected` is the normalized canonical.
   - **`n_stored_outputs`** (per testcase) = count of distinct stored outputs that stdin carried
     before canonical was picked (noise/ambiguity signal; index-aligned inside each testcase object,
     not a parallel `meta` array, so it can't desync).

5. **Publish** — new `Publish` (separate task, never auto): `System.cmd("hf", ["upload", repo, dir,
   "--repo-type", "dataset", ...])`; auth via `HF_TOKEN`; `--dry-run` prints the command.

## Licensing
rStar-Coder is **CC BY 4.0** (verified on its HF card) — redistribution of derivatives permitted with
**attribution + indication of changes**, no share-alike. Ship our dataset **CC BY 4.0**, **public**.
**Do not ship the problem statement (`question`)** — the underlying Codeforces/CodeChef statements
carry separate third-party copyright the card disclaims; shipping only solution source + I/O testcases
stays within the part rStar-Coder's CC BY 4.0 cleanly covers, and eval matches on stdout anyway.
`dataset_card.md` must: credit `microsoft/rStar-Coder`, link the license, and state changes —
*"filtered to a deterministically-verifiable subset; outputs re-derived and normalized; near-duplicate
tasks merged; problem statements removed."*

Mix tasks: `Mix.Tasks.Dataset.Build` (OptionParser + `:counters` progress + `Task.async_stream`,
templated on `tools/eval/lib/mix/tasks/eval.run.ex`) and `Mix.Tasks.Dataset.Publish`.

## Sandboxing (NEW — `Eval.Execute` has none; bulk untrusted execution)
Wrap the python invocation (configurable prefix `PYLIXIR_DATASET_SANDBOX`; default below). The plan's
original `unshare -n` is **broken unprivileged** (`Operation not permitted` — needs `CAP_SYS_ADMIN`).
The working incantation enters a **user namespace first**, which grants the capability to create the
netns (verified on this box):

```
unshare --user --map-root-user --net -- prlimit --as=<bytes> --cpu=<sec> -- python3.14 <file>
```

- `--user --map-root-user` — runs the sample as fake-uid-0 **inside a disposable user namespace**
  (root only within the throwaway ns, mapped to the real unprivileged uid; standard and safe).
- `--net` — loopback-only netns (verified: `socket.create_connection('1.1.1.1',80)` → `OSError`). No
  exfiltration/downloads.
- `prlimit --as` (address space) + `--cpu` — memory + CPU caps. **`--nproc` dropped as the primary
  fork guard** (`RLIMIT_NPROC` is per-real-uid system-wide → spurious fork failures counting the
  BEAM's own processes, and evadable under map-root); keep wall-clock SIGKILL (existing port logic) as
  the outer guard. `--nproc` optional + generous only.
- **Output-size cap** is enforced in the **port drain** (abort + SIGKILL if accumulated stdout exceeds
  the cap) — `prlimit --fsize` limits *file* size, not the stdout pipe, so it does **not** apply. The
  cap is **relative**: `len(expected) + 1 MB` (a fixed cap would falsely drop the ~9% of testcases
  whose legitimate `expected` exceeds it; relative kills only genuinely unbounded output).

**Fail-closed via a startup self-test:** before processing, run the configured sandbox prefix on a
probe that prints a sentinel **and** attempts an outbound socket; assert sentinel present **and**
connect failed. If either check fails → abort (catches missing binary AND non-isolated network). Unit
tests on the fake dataset override `PYLIXIR_DATASET_SANDBOX` (empty — they execute no untrusted code).

## Resumability / scale
Drive `Dataset.Build` by `--qid-shard i/N` (over **merge-groups**) or `--skip/--limit`.
Content-addressed cache keyed on **`(source, stdin)`** (append-only JSONL + ETS) is the backbone —
restart skips completed work; the verdict already encodes the 5-run reproducibility result. Output
parquet per shard. `provenance.json`: source repo + revision, shards/qid-range, interpreter banner,
**runs_per_testcase=5 (PYTHONHASHSEED unset)**, normalization rule, merge predicate (≥3 shared stdins,
zero-disagreement, transitive), curation size filter (1 MB), testcase cap/budgets, sandbox
incantation, tool git SHA, timestamp.
Bump dataset version on any ground-truth-affecting change (interpreter, run count, normalization,
merge predicate).

## Tunables (flags; all easily changed)
- runs per testcase: **5**
- testcases/merge-group cap: **32** (by stdin-sha, pre-verification)
- merge predicate: **≥3** shared stdins, **0** disagreements, transitive
- curation size filter: drop testcase if `stdin > 1 MB` **or** `expected > 1 MB`
- per-testcase CPU limit `prlimit --cpu`: **15 s**; wall-clock SIGKILL: **20 s**
- `prlimit --as`: **2 GB** (× `Task.async_stream` concurrency must fit host RAM)
- output-size cap (port drain, relative): **`len(expected) + 1 MB`**

## Out of scope (separate, downstream)
- **Transpilation / pylixir / Elixir-matchability** — not this app.
- **Eval integration** — eval consuming the filtered repo, skipping its CPython preflight, comparing
  with the same conservative normalizer: a downstream change, separate plan. Noted only as the
  contract: eval will read the filtered dataset and use the matching normalizer.

## Verification (of the curator)
1. Unit tests with a fake dataset module (reuse `Corpus`'s `:dataset_module` injection; sandbox prefix
   empty): set-print → dropped (5 runs vary); `sorted(...)` → kept; unseeded `random` → dropped;
   `random.seed(42); ...` → kept; output matches no stored expected → dropped; matches one of several
   conflicting stored → kept; trailing-space-only diff → kept; dedup + early-stop selection; merge
   grouping (≥3 shared + agree → merged; disagree → not merged; transitive chain).
2. Round-trip: emit parquet+jsonl for a tiny set, re-read via Explorer, assert schema + canonical.
3. Contract: re-run a sample of shipped rows (fresh process, seed randomized) → assert
   `normalize(stdout) == stored canonical`.
4. Sandbox self-test passes; `Dataset.Publish --dry-run` prints the `hf upload` command; manual
   `HF_TOKEN` check.

## Unresolved
1. HF **repo name** under the user's namespace (license = CC BY 4.0 public, no question text — settled
   above; only the repo id string remains).
2. Confirm tunable defaults (CPU/wall/mem/output-cap above) once a real shard is timed.
