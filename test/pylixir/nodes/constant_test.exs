defmodule Pylixir.Nodes.ConstantTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, UnsupportedNodeError}

  defp constant(value, extra \\ %{}),
    do: Map.merge(%{"_type" => "Constant", "value" => value}, extra)

  describe "supported literal types — value passes through as Elixir AST" do
    test "integer" do
      {ast, _ctx} = Converter.convert(constant(42), Context.new())
      assert ast == 42
    end

    test "negative integer (Python parsers produce UnaryOp(USub, Constant(5)) but a -5 literal is also legal)" do
      {ast, _ctx} = Converter.convert(constant(-5), Context.new())
      assert ast == -5
    end

    test "float" do
      {ast, _ctx} = Converter.convert(constant(3.14), Context.new())
      assert ast == 3.14
    end

    test "string" do
      {ast, _ctx} = Converter.convert(constant("hello"), Context.new())
      assert ast == "hello"
    end

    test "empty string" do
      {ast, _ctx} = Converter.convert(constant(""), Context.new())
      assert ast == ""
    end

    test "boolean true (JSON true → Elixir true)" do
      {ast, _ctx} = Converter.convert(constant(true), Context.new())
      assert ast === true
    end

    test "boolean false" do
      {ast, _ctx} = Converter.convert(constant(false), Context.new())
      assert ast === false
    end

    test "None (JSON null → Elixir nil)" do
      {ast, _ctx} = Converter.convert(constant(nil), Context.new())
      assert ast === nil
    end
  end

  describe "context threading" do
    test "context flows through unchanged (Constant is pure-data)" do
      ctx = Context.new(MapSet.new(["foo"]))
      {_ast, new_ctx} = Converter.convert(constant(1), ctx)
      assert new_ctx == ctx
    end
  end

  describe "unsupported tagged literals (T33 envelope)" do
    test "complex literal raises with kind + repr in the hint" do
      tagged = %{"_unsupported_literal" => "complex", "repr" => "3+4j"}

      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(
            constant(tagged, %{"lineno" => 7, "col_offset" => 4}),
            Context.new()
          )
        end

      assert err.node_type == "Constant"
      assert err.hint =~ "complex"
      assert err.hint =~ "3+4j"
      assert err.lineno == 7
      assert err.col_offset == 4
    end

    test "bytes literal raises with kind + repr in the hint" do
      tagged = %{"_unsupported_literal" => "bytes", "repr" => "b'hello'"}

      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(
            constant(tagged, %{"lineno" => 2, "col_offset" => 0}),
            Context.new()
          )
        end

      assert err.hint =~ "bytes"
      assert err.hint =~ "b'hello'"
      assert err.lineno == 2
    end

    test "ellipsis literal raises with kind in the hint" do
      tagged = %{"_unsupported_literal" => "ellipsis"}

      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(
            constant(tagged, %{"lineno" => 1, "col_offset" => 0}),
            Context.new()
          )
        end

      assert err.hint =~ "Ellipsis"
    end

    test "unknown _unsupported_literal kind falls back to a generic hint" do
      tagged = %{"_unsupported_literal" => "frozenset", "repr" => "frozenset()"}

      err =
        assert_raise UnsupportedNodeError, fn ->
          Converter.convert(constant(tagged), Context.new())
        end

      assert err.hint =~ "frozenset"
    end
  end

  describe "integration with the wider pipeline" do
    test "a Constant inside Module.body's runtime_statements roundtrips through to_source/1" do
      # Single bare expression at module top: `42`. Becomes an Expr(Constant)
      # in normal Python — but for this T06 test we use a literal-target
      # Assign so partitioning lands it as a @var_ module attribute and we
      # can confirm the Constant convert clause is reached.
      ast = %{
        "_type" => "Module",
        "body" => [
          %{
            "_type" => "Assign",
            "targets" => [%{"_type" => "Name", "id" => "X"}],
            "value" => %{"_type" => "Constant", "value" => 42}
          }
        ]
      }

      output = Pylixir.to_source(ast)
      assert output =~ "@var_X 42"
    end
  end
end
