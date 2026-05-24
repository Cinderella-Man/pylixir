Code.compiler_options(ignore_module_conflict: true)
ExUnit.start()

# CompilePool is required by `Eval.Compile.check/1` and
# `check_and_execute_testcases/4`, both of which the tests exercise
# without going through the Mix task entry point.
Eval.CompilePool.ensure_started()

# Trace envelopes (example inference) are cached in `Eval.TraceCache`.
# Boot an in-memory-only cache (no_cache: true) so test runs don't bleed
# state or touch the real cache file. (Tests that pass `no_examples: true`
# never hit it; this keeps the example path available for the others.)
Eval.TraceCache.ensure_started(
  path:
    Path.join(
      System.tmp_dir!(),
      "pylixir_eval_test_trace_cache_#{System.unique_integer([:positive])}.jsonl"
    ),
  no_cache: true
)
