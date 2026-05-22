defmodule Dataset do
  @moduledoc """
  `pylixir_dataset` — curator for a verified Python stdin/stdout dataset.

  Standalone, pylixir-free tool that filters `microsoft/rStar-Coder` down
  to a clean, *deterministically verifiable* subset and publishes it to
  HuggingFace. "Verifiable" = a Python solution reproduces its testcases'
  answers byte-identically across repeated runs, and that output matches a
  stored expected under a conservative normalizer.

  This does NOT transpile and does NOT involve pylixir — see
  `docs/12_dataset-curation-plan.md` for scope and the full design, and
  `docs/13_dataset-build-tasks.md` for the build order.

  ## Pipeline (stages → modules)

    0. `Dataset.MergeGroups` — global near-duplicate task grouping.
    1. `Dataset.Dataset` + `Dataset.Corpus` + `Dataset.Candidates` —
       fetch, join, dedup, per-group pools.
    2. `Dataset.Verify` — the reproducibility + correctness gate.
    3. `Dataset.Select` — one canonical solution per task.
    4. `Dataset.Emit` — parquet + JSONL + provenance + card.
    5. `Dataset.Publish` — `hf upload` (never automatic).

  Driven by `mix dataset.build` and `mix dataset.publish`.

  The interpreter is pinned to **python3.14** (`@default_python`); outputs
  are version-sensitive and the pin is recorded in the dataset card.
  """

  @default_python "python3.14"

  @doc "The pinned CPython interpreter used for verification."
  @spec default_python() :: String.t()
  def default_python, do: @default_python
end
