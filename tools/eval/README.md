# pylixir-eval

Maintainer-only harness that runs Pylixir against a large Python corpus
(`microsoft/rStar-Coder`), transpiles each sample to Elixir,
executes both under their respective runtimes, and buckets the diffs so
the next failure to fix is obvious. Sibling Mix project — kept out of the
published `pylixir` Hex package so it doesn't drag in HTTP / dataset deps.

Run from `tools/eval/`:

```bash
mix eval.run --limit 1000        # transpile + execute + bucket; writes reports/run-<ts>/
mix eval.hints                   # rank failing buckets by frequency (latest run)
mix eval.show path/to/file.py    # print the Elixir Pylixir would emit
mix eval.probe path/to/file.py   # transpile + compile + run + diff one sample end-to-end
mix eval.diag  path/to/file.py   # recover dropped `Code.compile_quoted/1` diagnostics
```

## Data

**Input corpus.** Each record fed to the pipeline is a map of the shape:

```elixir
%{
  id: "seed_20188--1885810c",
  source: "n = int(input())\nprint(n * 2)\n",
  testcases: [
    %{stdin: "3\n", expected: "6\n"},
    %{stdin: "10\n", expected: "20\n"}
  ]
}
```

`Eval.Corpus.build/1` produces these by joining the `seed_sft` (source)
and `seed_testcase` (stdin/expected output) parquet shards under
`cache/parquet/`. First run streams from HuggingFace; subsequent runs
serve from disk.

**Tests aren't unit tests against Pylixir — they're data-in / data-out.**
Per sample, per testcase, the harness runs:

1. CPython on `source` with `stdin`, cached by `sha256(source <> "\0" <> stdin)`.
2. Transpile `source` → Elixir, compile, invoke `py_main` with the same stdin.
3. Compare three strings — `expected`, `python_stdout`, `elixir_stdout` —
   with a 4-way truth table (see `Eval`'s module doc). The worst per-testcase
   outcome becomes the sample's bucket.

Bucket keys look like `:ok`, `{:unsupported, "Call"}`,
`{:output_mismatch, "1"}`, `{:elixir_runtime_error, MatchError}`,
`:elixir_timeout`, `:python_timeout`, etc. Full ladder is in
`lib/eval/bucket.ex`.

## Outputs

```
cache/
  parquet/seed_sft/…             # HF dataset shards (streamed lazily)
  parquet/seed_testcase/…
  python.jsonl                   # cached CPython outcomes, keyed by sha
  corpus_v1.term.gz              # serialized joined corpus

reports/run-<ISO8601>/
  summary.md                     # human bucket table + headline metrics
  summary.json                   # same numbers, machine-readable (diffable run-to-run)
  failures/<bucket-slug>/NNN.py  # first K samples per failing transpile/compile bucket,
                                 # with `# sample id:`, `# bucket:`, `# metadata:` header
  mismatches/<fingerprint>/      # one dir per output-mismatch fingerprint, each containing
    NNN.py                       #   the Python source
    NNN.ex                       #   the Elixir Pylixir emitted
    NNN.summary.md               #   per-testcase outcome table
    NNN.testcase_<i>.{stdin,expected,python,elixir,diff}.txt
  ok/                            # only when --save-ok N: N (.py, .ex) before/after pairs

baselines/*.csv                  # hand-curated reference numbers for regression checks
```
