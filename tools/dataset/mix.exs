defmodule Dataset.MixProject do
  use Mix.Project

  def project do
    [
      app: :pylixir_dataset,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Standalone curator — deliberately NO `:pylixir` dependency. The
  # data/exec modules it needs are copied-and-renamed from `tools/eval`
  # (see docs/12_dataset-curation-plan.md §Structure). Dep versions
  # mirror `tools/eval` so the copied modules compile unchanged.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:explorer, "~> 0.10"},
      {:req, "~> 0.5"}
    ]
  end
end
