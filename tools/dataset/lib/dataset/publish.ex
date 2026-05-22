defmodule Dataset.Publish do
  @moduledoc """
  Stage 5 — upload an emitted dataset directory to HuggingFace via the
  `hf` CLI. **Never automatic** — only invoked by `mix dataset.publish`.
  See docs/12_dataset-curation-plan.md §Pipeline-5, §Licensing.

  Auth is via the `HF_TOKEN` environment variable (read by the `hf` CLI).
  `--dry-run` prints the exact command instead of running it.
  """

  @doc """
  The `hf` argument list to upload `dir` to dataset repo `repo`.
  """
  @spec command(String.t(), String.t()) :: [String.t()]
  def command(repo, dir) do
    ["upload", repo, dir, "--repo-type", "dataset"]
  end

  @doc """
  Render the full shell command (for `--dry-run` / logging).
  """
  @spec command_string(String.t(), String.t()) :: String.t()
  def command_string(repo, dir), do: "hf " <> Enum.join(command(repo, dir), " ")

  @doc """
  Upload `dir` to `repo`.

  ## Options
    * `:dry_run` — when true, returns `{:dry_run, command_string}` without
      executing.

  Returns `{:dry_run, cmd}`, `{:ok, output}`, or `{:error, reason}`.
  """
  @spec publish(String.t(), String.t(), keyword()) ::
          {:dry_run, String.t()} | {:ok, String.t()} | {:error, term()}
  def publish(repo, dir, opts \\ []) do
    cond do
      Keyword.get(opts, :dry_run, false) ->
        {:dry_run, command_string(repo, dir)}

      not File.dir?(dir) ->
        {:error, {:no_such_dir, dir}}

      System.get_env("HF_TOKEN") in [nil, ""] ->
        {:error, :missing_hf_token}

      true ->
        case System.cmd("hf", command(repo, dir), stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          {out, status} -> {:error, {:hf_failed, status, out}}
        end
    end
  end
end
