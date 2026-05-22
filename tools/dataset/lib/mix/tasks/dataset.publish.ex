defmodule Mix.Tasks.Dataset.Publish do
  @shortdoc "Upload an emitted dataset dir to HuggingFace (never automatic)"
  @moduledoc """
  Publish a curated dataset directory to a HuggingFace dataset repo.

      mix dataset.publish REPO --dir out/v0 [--dry-run]

  `REPO` is the target dataset repo id (e.g. `you/rstar-coder-verified-io`).
  Auth via the `HF_TOKEN` environment variable. `--dry-run` prints the
  `hf upload` command without running it.

  ## Options
      --dir DIR     directory to upload (default out/v0)
      --dry-run     print the command, do not execute
  """
  use Mix.Task

  @switches [dir: :string, dry_run: :boolean]

  @impl true
  def run(argv) do
    {parsed, rest, invalid} = OptionParser.parse(argv, strict: @switches)
    unless invalid == [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    repo =
      case rest do
        [repo] -> repo
        _ -> Mix.raise("usage: mix dataset.publish REPO [--dir DIR] [--dry-run]")
      end

    dir = Keyword.get(parsed, :dir, "out/v0")

    case Dataset.Publish.publish(repo, dir, dry_run: Keyword.get(parsed, :dry_run, false)) do
      {:dry_run, cmd} ->
        Mix.shell().info(cmd)

      {:ok, out} ->
        Mix.shell().info(out)
        Mix.shell().info("[publish] uploaded #{dir} → #{repo}")

      {:error, :missing_hf_token} ->
        Mix.raise("HF_TOKEN is not set — export it before publishing")

      {:error, {:no_such_dir, d}} ->
        Mix.raise("no such directory: #{d}")

      {:error, reason} ->
        Mix.raise("publish failed: #{inspect(reason)}")
    end
  end
end
