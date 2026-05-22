defmodule DatasetTest do
  use ExUnit.Case, async: true
  doctest Dataset

  test "default_python is pinned to python3.14" do
    assert Dataset.default_python() == "python3.14"
  end
end
