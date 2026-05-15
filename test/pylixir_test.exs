defmodule PylixirTest do
  use ExUnit.Case, async: true
  doctest Pylixir

  alias Pylixir.UnsupportedNodeError

  describe "to_source/1" do
    test "dispatches through Converter — raises on a not-yet-supported Module node" do
      # Module clause lands in T05. Until then, hitting the catch-all proves
      # the pipeline is wired correctly.
      assert_raise UnsupportedNodeError, ~r/Module/, fn ->
        Pylixir.to_source(%{"_type" => "Module", "body" => []})
      end
    end
  end
end
