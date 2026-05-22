import Config

# Progress lines (`[corpus]`/`[merge]`/`[build]`) go through Logger.
# Strip the default timestamp/level decoration so real `mix dataset.build`
# runs look like the plain prints they replaced. Tests capture these (see
# test/test_helper.exs) so a passing run is silent.
config :logger, :console, format: "$message\n"
