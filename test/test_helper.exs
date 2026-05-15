# Generated modules from `Pylixir.TranspileHelpers` use a unique atom per
# invocation, so collisions should not happen in practice. This is
# belt-and-braces in case a helper bug causes one.
Code.compiler_options(ignore_module_conflict: true)

ExUnit.start()
