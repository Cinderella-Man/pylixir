# pylixir-eval

Maintainer-only harness that runs Pylixir against a curated, verified
Python corpus, transpiles each sample to Elixir, runs it, and buckets the
diffs against the dataset's verified output so the next failure to fix is
obvious. Sibling Mix project — kept out of the published `pylixir` Hex
package so it doesn't drag in HTTP / dataset deps.

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
    %{stdin: "3\n", expected: "6"},
    %{stdin: "10\n", expected: "20"}
  ]
}
```

`Eval.Corpus.build/1` streams these straight from the curated dataset
[`CinderellaMan/rstar-coder-verified-io-deduped`](https://huggingface.co/datasets/CinderellaMan/rstar-coder-verified-io-deduped)
— one `data.parquet` whose rows are already joined, deduped, and verified
(`expected` is the deterministic, normalized CPython output). First run
downloads it to `cache/data.parquet`; subsequent runs read from disk
(delete the file to refresh).

**Tests aren't unit tests against Pylixir — they're data-in / data-out.**
Per sample, per testcase, the harness runs:

1. Transpile `source` → Elixir, compile, invoke `py_main` with `stdin`.
2. Compare the Elixir stdout to the dataset's `expected` under the
   canonical normalizer (`Eval.Execute.compare/2`). The worst per-testcase
   outcome becomes the sample's bucket.

(CPython is run only to capture trace envelopes for example-guided
transpilation, cached in `cache/python_traces.jsonl`.)

Bucket keys look like `:ok`, `{:unsupported, "Call"}`,
`{:output_mismatch, "1"}`, `{:elixir_runtime_error, MatchError}`,
`:elixir_timeout`, etc. Full ladder is in `lib/eval/bucket.ex`.

## Outputs

```
cache/
  data.parquet                   # curated dataset (downloaded once; rm to refresh)
  python_traces.jsonl            # cached CPython tracer envelopes (example inference)

reports/run-<ISO8601>/
  summary.md                     # human bucket table + headline metrics
  summary.json                   # same numbers, machine-readable (schema_version 4)
  failures/<bucket-slug>/NNN.py  # first K samples per failing transpile/compile bucket,
                                 # with `# sample id:`, `# bucket:`, `# metadata:` header
  mismatches/<fingerprint>/      # one dir per output-mismatch fingerprint, each containing
    NNN.py                       #   the Python source
    NNN.ex                       #   the Elixir Pylixir emitted
    NNN.summary.md               #   per-testcase outcome table
    NNN.testcase_<i>.{stdin,expected,elixir,diff}.txt
  ok/                            # only when --save-ok N: N (.py, .ex) before/after pairs

baselines/*.csv                  # hand-curated reference numbers for regression checks
```
