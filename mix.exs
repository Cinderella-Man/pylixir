defmodule Pylixir.MixProject do
  use Mix.Project

  @source_url "https://github.com/Cinderella-Man/pylixir"
  @version "0.1.0"

  def project do
    [
      app: :pylixir,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Pylixir",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:jason, "~> 1.4"}
    ]
  end

  defp description do
    "Source-to-source compiler that turns a Python AST (decoded JSON) into " <>
      "self-contained Elixir source code."
  end

  defp package do
    [
      maintainers: ["Kamil Skowron"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # Explicit allowlist of what ships in the Hex tarball. `tools/`
      # is a maintenance subapp (eval harness) and is deliberately
      # excluded — likewise `docs/plan.md` (internal planning) and
      # everything under `test/`, `_build/`, `deps/`, `tmp/`.
      files: ~w(
        lib
        priv
        mix.exs
        README.md
        LICENSE
        CHANGELOG.md
        CONTEXT.md
        implementation.md
        docs/rfc.md
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CONTEXT.md",
        "implementation.md",
        "docs/rfc.md": [title: "RFC — Specification"]
      ]
    ]
  end
end
