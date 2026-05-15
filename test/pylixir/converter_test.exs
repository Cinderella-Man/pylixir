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

  describe "collect_function_names/1" do
    test "returns an empty set for an empty body" do
      assert Converter.collect_function_names([]) == MapSet.new()
    end

    test "extracts FunctionDef names from a flat module body" do
      body = [
        %{"_type" => "FunctionDef", "name" => "fib"},
        %{"_type" => "Assign", "targets" => [], "value" => nil},
        %{"_type" => "FunctionDef", "name" => "main"}
      ]

      assert Converter.collect_function_names(body) == MapSet.new(["fib", "main"])
    end

    test "ignores nested FunctionDefs (only top-level names are collected)" do
      body = [
        %{
          "_type" => "FunctionDef",
          "name" => "outer",
          "body" => [%{"_type" => "FunctionDef", "name" => "inner"}]
        }
      ]

      assert Converter.collect_function_names(body) == MapSet.new(["outer"])
    end
  end
end
