Code.compiler_options(ignore_module_conflict: true)
ExUnit.start()

# CompilePool is required by Eval.Compile.check/1 and friends, which
# golden-fixture and other tests exercise without going through the
# Mix task entry point.
Eval.CompilePool.ensure_started()
