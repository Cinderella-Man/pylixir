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

    test "the exception carries lineno and col_offset when the node provides them" do
      ctx = Context.new()

      err =
        try do
          Converter.convert(
            %{"_type" => "ClassDef", "lineno" => 14, "col_offset" => 2},
            ctx
          )

          flunk("expected UnsupportedNodeError")
        rescue
          e in UnsupportedNodeError -> e
        end

      assert err.lineno == 14
      assert err.col_offset == 2
      assert err.message =~ "line 14"
      assert err.message =~ "col 2"
    end

    test "looks up a hint from the @hints table for known unsupported types" do
      ctx = Context.new()

      err =
        try do
          Converter.convert(%{"_type" => "ClassDef", "lineno" => 1, "col_offset" => 0}, ctx)
          flunk("expected UnsupportedNodeError")
        rescue
          e in UnsupportedNodeError -> e
        end

      assert err.hint != nil
      assert err.message =~ "classes are not supported"
    end

    test "falls back gracefully when the node has no location info (synthesized nodes)" do
      ctx = Context.new()

      err =
        try do
          Converter.convert(%{"_type" => "ClassDef"}, ctx)
          flunk("expected UnsupportedNodeError")
        rescue
          e in UnsupportedNodeError -> e
        end

      assert err.lineno == nil
      assert err.col_offset == nil
      refute err.message =~ "line"
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
