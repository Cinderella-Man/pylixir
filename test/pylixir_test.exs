defmodule PylixirTest do
  use ExUnit.Case
  doctest Pylixir

  describe "to_source/1" do
    test "stub returns an empty binary" do
      assert Pylixir.to_source(%{"_type" => "Module", "body" => []}) == ""
    end
  end
end
