Code.compiler_options(ignore_module_conflict: true)
ExUnit.start()

# CompilePool is required by `Eval.Compile.check/1` and
# `check_and_execute_testcases/4`, both of which the tests exercise
# without going through the Mix task entry point.
Eval.CompilePool.ensure_started()

# `Eval.process/2` always goes through the per-testcase Python path,
# which calls `Eval.PythonCache.lookup/1`. Boot with an in-memory-only
# cache (no_cache: true) on a unique tmp path so test runs don't bleed
# state into each other or into the real cache file.
Eval.PythonCache.ensure_started(
  path:
    Path.join(
      System.tmp_dir!(),
      "pylixir_eval_test_python_cache_#{System.unique_integer([:positive])}.jsonl"
    ),
  no_cache: true
)
