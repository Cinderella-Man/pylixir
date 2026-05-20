# Eval harness: behavioral equivalence (post-grill)

## Context

`tools/eval` currently classifies on transpile+compile only. Goal: execute both Python and transpiled Elixir, compare stdout byte-equal. Pattern already exists in `test/pylixir/golden_corpus_test.exs` + `test/support/transpile_helpers.ex` (for 150 fixtures); we're lifting it to the 10k HF corpus with concurrency, timeouts, caching, determinism detection, and richer bucketing.

Dataset (`microsoft/rStar-Coder`) ships no test inputs — comparison is script-mode stdout vs script-mode stdout, stdin `/dev/null` both sides. `PYTHONHASHSEED=0` for reproducibility.

Pylixir already ships `py_str`/`py_repr` (`runtime_helpers.ex:497-674`) that emulate Python formatting. Set repr uses `MapSet.to_list/1` — known mismatch source vs CPython hash-bucket order; the eval should *surface* this, not paper over.

Stylistic warning filter (`bucket.ex:107-119`) stays — those messages are Pylixir deliberate codegen noise; the new behavioral gate is the dispositive signal.

## Resolved decisions

1. **Python-first preflight.** Python runs *before* Elixir. If Python fails, skip equivalence check.
2. **Sub-classify Python failures** by parsing exception class from stderr last line: `:python_syntax_error`, `:python_import_error`, `{:python_error, ExceptionClass}` (NameError, TypeError, …), `:python_timeout`.
3. **Strict byte-equal stdout**, only `\r\n → \n` normalization. `PYTHONHASHSEED=0` env on Python subprocesses.
4. **Determinism via double-run.** First time a source is seen: run Python twice. If outputs differ → `:nondeterministic_observed`. If outputs match → cache that stdout. Subsequent runs trust the cache.
5. **Python output cache.** `tools/eval/cache/python.jsonl`, content-addressed by SHA-256 of source. Schema below.
6. **Split timeouts.** `--python-timeout` default 3000ms; `--elixir-timeout` default 5000ms. `:python_timeout` distinct from `:python_broken` family.
7. **CompilePool size = concurrency.** Pass `size: concurrency` into `ensure_started/1`, called *after* opts parsing (currently started at `eval.run.ex:60` pre-opts — needs reorder).
8. **`:elixir_runtime_error` sub-classified** as `{:elixir_runtime_error, ExceptionModule}` — same shape as `:compile_error`.
9. **Diff format: custom first-difference summary.** No subprocess, no Hex dep.
10. **Report schema versioning.** Add `schema_version: 2` and run-level `comparison_mode: "executed" | "compile_only"` to `summary.json`. No per-sample execution_mode flag.
11. **`setsid` + `kill -<pgid>`** on Python timeout to nuke the whole process group, not just the direct child.
12. **`try/after File.rm`** for Python tmp files — no leaks across 10k runs.
13. **`{:output_mismatch, fingerprint}`**: fingerprint = first 60 chars of first divergent line (matches `:compile_error` precedent).
14. **`--execute` default ON**; `--no-execute` opts back to compile-only.
15. **`:ok_empty_output` distinct from `:ok`** — surfaces vacuous matches (function defs without calls).

## Per-sample pipeline

```
source ──▶ Eval.PythonCache.lookup(sha256)
            │
            ├─ HIT, outcome=ok ──────────────┐
            ├─ HIT, outcome=error ─────▶ {:python_*, …} bucket; STOP
            ├─ HIT, outcome=timeout ──▶ :python_timeout;        STOP
            ├─ HIT, outcome=nondet ──▶ :nondeterministic_observed; STOP
            └─ MISS ─▶ Execute.run_python ×2 (PYTHONHASHSEED=0, /dev/null stdin)
                       │
                       ├─ either timed out → cache :timeout;  STOP
                       ├─ either errored   → cache :error;   STOP
                       ├─ stdouts differ   → cache :nondet;  STOP
                       └─ stdouts match    → cache :ok with stdout ─┐
                                                                     │
            ┌────────────────────────────────────────────────────────┘
            ▼
       Pylixir.transpile  ──── fails ──▶ existing :unsupported / :parse_error / :internal
            │
            ▼
       Compile.check (inside CompilePool slot)
            │
            ├─ raised  ──▶ :compile_error / :internal
            └─ ok      ──▶ Execute.run_elixir (still in slot, before :code.delete/purge)
                           │
                           ├─ raised  ──▶ {:elixir_runtime_error, ExceptionModule}
                           ├─ timeout ──▶ :elixir_timeout
                           └─ ok      ──▶ compare to cached python_stdout
                                          │
                                          ├─ equal, empty   → :ok_empty_output
                                          ├─ equal, nonempty→ :ok
                                          └─ differ         → {:output_mismatch, fp}
```

## Bucket key reference

| Bucket | Meaning | Metadata |
|---|---|---|
| `:ok` | Stdouts match, non-empty | `:elixir_source` |
| `:ok_empty_output` | Stdouts match, both empty | `:elixir_source` |
| `{:output_mismatch, fp}` | Both ran, stdouts differ | `:python_stdout`, `:elixir_stdout`, `:diff_summary` |
| `{:elixir_runtime_error, Mod}` | Elixir compiled, `py_main/0` raised | `:exception`, `:message` |
| `:elixir_timeout` | Elixir exceeded `--elixir-timeout` | — |
| `:python_syntax_error` | CPython failed to parse | `:stderr_tail` |
| `:python_import_error` | `ImportError`/`ModuleNotFoundError` | `:missing_module` |
| `{:python_error, Class}` | Other CPython exception | `:exception_class`, `:stderr_tail` |
| `:python_timeout` | Python exceeded `--python-timeout` | — |
| `:nondeterministic_observed` | Two Python runs diverged | — |
| `:unsupported`, `:parse_error`, `:compile_error`, `:internal` | Existing transpile/compile failure buckets — unchanged | as today |

## Module changes

### New: `tools/eval/lib/eval/python_cache.ex`

GenServer. State: `%{sha => entry}`. Lifecycle:

- `ensure_started/1` — boot at `eval.run.ex` startup. Load `tools/eval/cache/python.jsonl` (if exists) into the map. Stat-check `python_version` + `hashseed` on each entry; ignore mismatches (will be re-run + overwritten).
- `lookup(sha) :: {:hit, entry} | :miss`
- `put(sha, entry)` — async cast; appends a JSONL line to the file (serialized through the GenServer process).
- Entry schema:
  ```json
  {
    "sha256": "<hex>",
    "python_version": "3.14.0",
    "hashseed": "0",
    "outcome": "ok|syntax_error|import_error|error|timeout|nondeterministic",
    "stdout": "<str>",          // when outcome=ok
    "exit_code": 1,             // when outcome=error
    "exception_class": "...",   // when outcome=error/import_error/syntax_error
    "missing_module": "...",    // when outcome=import_error
    "stderr_tail": "<str>",     // when outcome=error/syntax_error
    "elapsed_ms": 142,
    "created_at": "ISO8601"
  }
  ```

### New: `tools/eval/lib/eval/execute.ex`

- `run_python(source, opts) :: {:ok, stdout} | {:timeout} | {:exit, code, stderr}`
  - Write source to unique tmp under `tools/eval/tmp/<sha-prefix>-<unique>.py`.
  - `Port.open({:spawn_executable, sh}, [:binary, :exit_status, :stderr_to_stdout, :hide, args: ["-c", "exec setsid '#{py}' '#{tmp}' < /dev/null"]])`.
  - `env: [{"PYTHONHASHSEED", "0"}, {"PYTHONWARNINGS", "ignore"}]`.
  - Receive loop with `after timeout_ms ->` → `Port.close`; resolve `Port.info(p, :os_pid)` → `System.cmd("kill", ["-KILL", "-#{pgid}"])` (negative PID = process group).
  - `try ... after File.rm(tmp_path) end` envelope.
  - `python_cmd/0` resolves `PYLIXIR_PYTHON` (default `python3.14`) — same as `lib/pylixir.ex:67-68`.
- `run_elixir(module_atom, timeout_ms) :: {:ok, stdout} | {:timeout} | {:raised, exception}`
  - `Task.async` wrapping `ExUnit.CaptureIO.capture_io(fn -> module.py_main() end)`.
  - `Task.yield(t, timeout) || Task.shutdown(t, :brutal_kill)`.
  - Catches `throw {:pylixir_exit, _}` (per `converter.ex:3038-3041`).
- `compare_outputs(python_stdout, elixir_stdout) :: :equal | :equal_empty | {:differ, fingerprint, summary}`
  - Normalize `\r\n → \n` both sides, then `==`.
  - Empty = `String.trim_trailing("\n") == ""`.
  - Fingerprint = first 60 chars of expected at first divergent line.
  - Summary string format:
    ```
    expected: N lines
    actual:   M lines
    first divergence at line K:
      expected: "<60-char-snippet>"
      actual:   "<60-char-snippet>"
    ```

### Modified: `tools/eval/lib/eval/compile.ex`

Add `check_and_execute(source, timeout_ms) :: {:ok, diagnostics, stdout} | {:raised, diagnostics, exception} | {:timeout, diagnostics} | {:error, exception}`. Inside `CompilePool.with_slot` callback:

```
try do
  compile (existing logic)
  case compile_outcome do
    :ok -> Execute.run_elixir(Module.concat(Elixir, alias_atom), timeout)
    {:raised, _} -> compile_outcome   # short-circuit
  end
after
  :code.delete(module); :code.purge(module)
end
```

Existing `check/1` retained for `--no-execute` callers.

### Modified: `tools/eval/lib/eval/bucket.ex`

Extend `outcome()` type with the new variants. Add `bucket_key/metadata` clauses for each new bucket. Add `slug/1` clauses for new keys (escape commas/parens/colons in exception class names through existing `sanitize/1`).

`stylistic?/1` filter unchanged.

### Modified: `tools/eval/lib/eval.ex`

- `opts()` += `{:execute, boolean}` (default true), `{:python_timeout_ms, pos_integer}` (default 3000), `{:elixir_timeout_ms, pos_integer}` (default 5000).
- `attempt/1` → `attempt/2(sample, opts)`. New body:

```
sha = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

case PythonCache.lookup(sha) do
  :miss ->
    res = run_python_twice(source, opts) |> classify_python
    PythonCache.put(sha, res)
    res
  {:hit, entry} -> entry
end
|> case do
  %{outcome: "ok", stdout: py_out} -> attempt_elixir(sample, py_out, opts)
  %{outcome: "syntax_error"} -> {:python_syntax_error, …}
  …
end
```

- `process/2` signature unchanged. Threads `opts` into the worker closure.

### Modified: `tools/eval/lib/mix/tasks/eval.run.ex`

Switches += `execute: :boolean` (default true), `no_execute: :boolean`, `python_timeout: :integer`, `elixir_timeout: :integer`, `no_python_cache: :boolean`, `rebuild_python_cache: :boolean`.

Reorder startup:
1. `Mix.Task.run("app.start")`
2. `Application.ensure_all_started(:ex_unit)` (for `CaptureIO`; doesn't boot test runner)
3. Parse opts → resolve concurrency
4. `Eval.CompilePool.ensure_started(size: concurrency)`
5. `Eval.PythonCache.ensure_started(path: ..., no_cache: opts[:no_python_cache], rebuild: opts[:rebuild_python_cache])`

### Modified: `tools/eval/lib/eval/report.ex`

- `summary.json` adds `schema_version: 2`, `comparison_mode: "executed" | "compile_only"`, `totals.equivalent`, `totals.python_broken`, `totals.nondeterministic`.
- `summary.md` separates "Transpile/Compile" and "Behavior" sections; headline line reports `Behavioral equivalence: X / Y (Z%)` or `Compile-success: X / Y (Z%)`.
- New per-bucket dir for `{:output_mismatch, _}`: `<NNN>.py`, `<NNN>.expected.txt`, `<NNN>.actual.txt`, `<NNN>.diff` (summary string).

### No change

`tools/eval/lib/eval/stream.ex` + `priv/python/dataset_stream.py` — `{id, source}` projection is sufficient.

## Concurrency & safety

1. **CompilePool slot** held for full compile+execute+delete+purge window. With `size = concurrency`, no slot starvation. Memory growth: `~330 × concurrency` BEAM export-staged entries, well under the 524K limit.
2. **`ExUnit.CaptureIO`** swaps the caller-process group leader. Each `Task.async_stream` worker spawns its own `Task.async` for the Elixir run → per-Task isolated capture. No cross-worker stdout bleed.
3. **`:code.delete + :code.purge`** in `after` block — runs whether `py_main` returns, raises, or is brutal-killed. In brutal-kill case the runner task is dead, so the module's not on any call stack.
4. **Python subprocess**: `setsid` puts each in its own process group; on timeout `kill -KILL -<pgid>` reaps all descendants. Unique tmp file per spawn.
5. **PythonCache** writes serialized via GenServer cast → no JSONL line tearing. Reads are pure-map lookups (no GenServer round-trip).
6. **Worst-case wall time** (10k samples, 16 concurrency):
   - First run (cold cache): `(3s × 2 + 5s)` worst × 10k / 16 ≈ **115 min**.
   - Realistic mean (~200ms Python + ~50ms Elixir): ~3 min.
   - Warm cache: only Elixir runs → ≈ **52 min** worst / **2 min** realistic.

## Critical files

- **New**: `tools/eval/lib/eval/execute.ex`, `tools/eval/lib/eval/python_cache.ex`
- **Modified**: `tools/eval/lib/eval/compile.ex`, `tools/eval/lib/eval/bucket.ex`, `tools/eval/lib/eval.ex`, `tools/eval/lib/mix/tasks/eval.run.ex`, `tools/eval/lib/eval/report.ex`

## Reuse references

- `test/support/transpile_helpers.ex:82-103` — compile+invoke+capture pattern.
- `test/pylixir/golden_corpus_test.exs:107-120` — Python subprocess with `/dev/null` stdin.
- `tools/eval/lib/mix/tasks/eval.probe.ex:154-165` — `sh -c 'exec python3 ... < /dev/null'` precedent.
- `lib/pylixir/converter.ex:3018-3041` — `py_main/0` shape + `{:pylixir_exit, _}` throw.
- `lib/pylixir/runtime_helpers.ex:497-674` — `py_str`/`py_repr` Python-style formatting.

## Verification

```
# Cold-cache smoke
rm -f tools/eval/cache/python.jsonl
PYLIXIR_PYTHON=python3.14 mix eval.run --limit 20 --samples-per-bucket 10
```

Expect:
- `tools/eval/cache/python.jsonl` populated with ~20 entries.
- `reports/run-*/summary.md` shows behavioral section with mixed `:ok`, `:ok_empty_output`, `{:output_mismatch, _}`, and at least one Python-side bucket if rStar-Coder has typical noise.
- `summary.json` has `schema_version: 2` and `comparison_mode: "executed"`.

```
# Warm-cache run — should be MUCH faster
mix eval.run --limit 20 --samples-per-bucket 10
```

- Python should not run (no `python3` subprocesses visible via `ps` during the run).
- Bucket counts identical to cold run.

```
# Backward compat
mix eval.run --limit 20 --no-execute
```

- `summary.json` has `comparison_mode: "compile_only"`.
- Only transpile/compile buckets populated.
- Transpile/compile counts identical to behavioral-mode run (execute-mode doesn't change the upstream pipeline).

```
# Tight timeout smoke
mix eval.run --limit 50 --python-timeout 50 --elixir-timeout 50
```

- Non-zero `:python_timeout` and/or `:elixir_timeout` buckets.
- Run completes; no hanging processes (`pgrep -f python3 | wc -l` returns to baseline within seconds).

```
# Golden corpus still passes (sanity for shared logic)
mix test test/pylixir/golden_corpus_test.exs
```

## Unresolved questions

None.
