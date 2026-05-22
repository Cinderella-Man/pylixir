# Plan: `pylixir_dataset` — verified Python I/O dataset (curation only)

## Context
rStar-Coder's stored `expected` outputs are unreliable (whitespace junk, multiple-valid-answer
problems, genuinely-wrong solutions, non-determinism). This app curates a clean, **verifiable** subset
and publishes it to HuggingFace; the existing `eval` app later consumes it.

**Scope (important): this app does NOT transpile and does NOT involve pylixir.** It is purely
Python-side data generation. "Verifiable" = a Python solution *deterministically reproduces* its
testcases' stored answers. Those verifiable rows are good candidates for the *later, separate*
Python→Elixir transpilation+eval, but transpilability/Elixir-matchability is **not** assessed here.

## What "verified" means (keep a (solution, testcase) iff BOTH)
1. **Reproducible** — run the solution on the testcase's stdin **N times under varied `PYTHONHASHSEED`**
   (e.g. `0,1,2,3,<large>`); keep only if output is byte-identical (after normalization) on every run.
   Any variation → drop. This single dynamic rule catches unseeded `random`, wall-clock/time, AND
   set/dict hash-ordering (which is stable per-seed, so varying the seed is essential to expose it).
   No static source scan; no permutation-rescue. (Seeded `random` is genuinely deterministic so it is
   *kept* — it's verifiable; that pylixir can't reproduce MT19937 is the downstream eval's concern.)
2. **Correct** — the deterministic output equals the dataset's stored `expected` under the
   normalization below. Mismatch → drop (no majority-vote / "most-common" repair).

Canonical `expected` stored = the normalized output (== stored answer, by construction).

## Normalization (conservative — same rule for the match-gate and the stored canonical)
CRLF→LF, then **per-line trailing-whitespace trim** + trailing newline/blank-line trim; **leading and
internal spacing preserved exactly** (so `1 2 3` ≠ `1\n2\n3`; never conflates structurally different
output). Slightly more than eval's existing `lenient_normalize/1` (which doesn't rstrip per line) →
small new normalizer. Recovers only trailing-whitespace noise; leading/internal-spacing mismatches drop.

## Interpreter
Pin **python3.14** (parent's `@default_python`, lib/pylixir.ex:10) so canonical matches the eventual
downstream target. Record the exact version in the dataset card; outputs are version-sensitive.

## Pipeline (stages → modules)
1. **Fetch + join + dedup** — reuse eval's data infra: `Eval.Dataset.{download_shard/2,
   read_sft_shard/2, read_testcase_shard/3}` (HF download via Req + Polars read/pushdown) and
   `Eval.Corpus.build/1` (qid join, `is_passed=true`, sha256 solution dedup, `inputs`/`outputs` JSON
   parse). New `Candidates`: regroup by qid → `%{qid => %{solutions, testcases}}`, dedup testcases by
   `sha256(stdin)`, cap testcases/problem (default 32, deterministic by stdin-sha).
2. **Verify** — new `Verify`: for each candidate solution × testcase, run python3.14 under the seed
   set; keep the testcase for that solution iff reproducible + matches stored (conservative norm).
   Cache per `(source, stdin, seed)` (seed-aware key over the `Eval.PythonCache` design) → resumable.
3. **Select** — new `Select`: per problem, pick ONE solution maximizing verified-testcase count
   (tie-break shortest source, then sha). Ship that solution + its verified testcases; record
   alternates' shas in meta. Drop the problem if no solution verifies ≥1 testcase.
4. **Emit** — new `Emit`: parquet via `Explorer.DataFrame.to_parquet/2` with `testcases`/`meta` as
   **JSON-string columns** (avoids Explorer nested-type edges; mirrors how raw `inputs`/`outputs` are
   stored) + JSONL mirror + `provenance.json` + `dataset_card.md`, into `out/<version>/`.
5. **Publish** — new `Publish` (separate task, never auto): `System.cmd("hf", ["upload", repo, dir,
   "--repo-type", "dataset", ...])`; auth via `HF_TOKEN`; `--dry-run` prints the command.

Mix tasks: `Mix.Tasks.Dataset.Build` (OptionParser + `:counters` progress + `Task.async_stream`,
templated on `tools/eval/lib/mix/tasks/eval.run.ex`) and `Mix.Tasks.Dataset.Publish`.

## Structure / dependency
**Standalone — the curator must NOT depend on pylixir** (it never transpiles). The reused pieces
(`Eval.Dataset`, `Eval.Corpus`, `Eval.Execute`, `Eval.PythonCache`) are pure data/exec and don't call
pylixir, but they live in `tools/eval` which depends on pylixir. Keep the curator pylixir-free by
extracting those modules into a small shared lib both apps depend on (preferred — single source of
truth) or copying them initially. `Eval.Execute.run_python/2` needs a seed parameter — add an optional
`:hashseed` opt (default `"0"`, additive, backward-compatible) so one audited Port/SIGKILL path is
shared.

## Sandboxing (NEW — `Eval.Execute` has none; bulk untrusted execution)
Wrap the python invocation (configurable prefix `PYLIXIR_DATASET_SANDBOX`):
`unshare -n -- prlimit --as=<bytes> --cpu=<sec> --nproc=<N> --fsize=<bytes> -- python3.14 <file>`.
`unshare -n` = loopback-only netns (no exfiltration/downloads); `prlimit` = memory/CPU/fork-bomb/file
caps; keep wall-clock SIGKILL as outer guard. **Fail-closed** if the sandbox is unavailable.
(`unshare`+`prlimit` confirmed present; `firejail` absent.) Also caps huge-output / runaway cases.

## Resumability / scale
Drive `Dataset.Build` by `--qid-shard i/N` (or `--skip/--limit`). Seed-aware content-addressed cache
(append-only JSONL + ETS) is the backbone — restart skips completed work. Output parquet per shard.
`provenance.json`: source repo + revision, shards/qid-range, interpreter banner, seed list,
normalization rule, testcase cap/budgets, tool git SHA, timestamp. Bump dataset version on any
ground-truth-affecting change (interpreter, seeds, normalization).

## Out of scope (separate, downstream)
- **Transpilation / pylixir / Elixir-matchability** — not this app.
- **Eval integration** — eval consuming the filtered repo, skipping its CPython preflight, comparing
  with the same conservative normalizer: a downstream change, separate plan. Noted only as the
  contract: eval will read the filtered dataset and use the matching normalizer.

## Verification (of the curator)
1. Unit tests with a fake dataset module (reuse `Eval.Corpus`'s `:dataset_module` injection):
   set-print → dropped (multi-seed varies); `sorted(...)` → kept; unseeded `random` → dropped;
   `random.seed(42); ...` → kept (deterministic); mismatch-vs-stored → dropped; trailing-space-only
   diff → kept; dedup + selection behaviors.
2. Round-trip: emit parquet+jsonl for a tiny set, re-read via Explorer, assert schema + canonical.
3. Contract: re-run a sample of shipped rows at a *fresh* `PYTHONHASHSEED` → assert
   `normalize(stdout) == stored expected`.
4. `Dataset.Publish --dry-run` prints the `hf upload` command; manual `HF_TOKEN` check.

## Unresolved
1. HF target repo id + public/private + license/redistribution terms (derivative of
   microsoft/rStar-Coder).
2. Extract shared data/exec modules into a lib vs copy into the curator (both keep it pylixir-free).
3. Tunables: N seeds (proposed 5), testcases/problem cap (32), per-testcase runtime budget (~2s),
   output-size cap (256 KB) — acceptable defaults or tune?
