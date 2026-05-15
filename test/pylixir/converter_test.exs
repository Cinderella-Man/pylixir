defmodule Pylixir.ConverterTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, UnsupportedNodeError}

  describe "convert/2" do
    test "raises UnsupportedNodeError on unknown node type, exposing the _type string" do
      ctx = Context.new()

      assert_raise UnsupportedNodeError, ~r/ClassDef/, fn ->
        Converter.convert(%{"_type" => "ClassDef"}, ctx)
      end
    end

    test "the exception carries node_type as a structured field" do
      ctx = Context.new()

      err =
        try do
          Converter.convert(%{"_type" => "AsyncFunctionDef"}, ctx)
          flunk("expected UnsupportedNodeError")
        rescue
          e in UnsupportedNodeError -> e
        end

      assert err.node_type == "AsyncFunctionDef"
    end
  end
end
