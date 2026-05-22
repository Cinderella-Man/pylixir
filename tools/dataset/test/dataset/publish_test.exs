defmodule Dataset.PublishTest do
  use ExUnit.Case, async: true

  alias Dataset.Publish

  test "command builds the hf dataset-upload argument list" do
    assert Publish.command("me/repo", "out/v0") ==
             ["upload", "me/repo", "out/v0", "--repo-type", "dataset"]
  end

  test "command_string renders the full hf command" do
    assert Publish.command_string("me/repo", "out/v0") ==
             "hf upload me/repo out/v0 --repo-type dataset"
  end

  test "dry-run returns the command and does not execute" do
    assert {:dry_run, "hf upload me/repo out/v0 --repo-type dataset"} =
             Publish.publish("me/repo", "out/v0", dry_run: true)
  end

  test "errors on a missing directory before touching hf" do
    assert {:error, {:no_such_dir, _}} =
             Publish.publish("me/repo", "/definitely/not/here", dry_run: false)
  end
end
