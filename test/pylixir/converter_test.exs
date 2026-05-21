defmodule Pylixir.ConverterTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, Converter, UnsupportedNodeError}

  describe "convert/2" do
    test "raises UnsupportedNodeError on unknown node type, exposing the _type string" do
      ctx = Context.new()

      assert_raise UnsupportedNodeError, ~r/Yield/, fn ->
        Converter.convert(%{"_type" => "Yield"}, ctx)
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
            %{"_type" => "Yield", "lineno" => 14, "col_offset" => 2},
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
          Converter.convert(%{"_type" => "Yield", "lineno" => 1, "col_offset" => 0}, ctx)
          flunk("expected UnsupportedNodeError")
        rescue
          e in UnsupportedNodeError -> e
        end

      assert err.hint != nil
      assert err.hint =~ "generators"
    end

    test "falls back gracefully when the node has no location info (synthesized nodes)" do
      ctx = Context.new()

      err =
        try do
          Converter.convert(%{"_type" => "Yield"}, ctx)
          flunk("expected UnsupportedNodeError")
        rescue
          e in UnsupportedNodeError -> e
        end

      assert err.lineno == nil
      assert err.col_offset == nil
      refute err.message =~ "line"
    end
  end

  describe "typed truthy-drop in convert_test/2 and UnaryOp Not" do
    alias Pylixir.TypeInfer

    defp emit_if(src_body, ctx) do
      # Build a tiny `if <body>: pass` AST around the supplied test
      # expression node and convert it. Returns the rendered Elixir
      # source so we can assert on the emitted test shape.
      ast = %{
        "_type" => "If",
        "test" => src_body,
        "body" => [%{"_type" => "Pass"}],
        "orelse" => []
      }

      {elixir_ast, _ctx} = Converter.convert(ast, ctx)
      Macro.to_string(elixir_ast)
    end

    defp emit_unary_not(operand, ctx) do
      ast = %{"_type" => "UnaryOp", "op" => %{"_type" => "Not"}, "operand" => operand}
      {elixir_ast, _ctx} = Converter.convert(ast, ctx)
      Macro.to_string(elixir_ast)
    end

    defp name(id), do: %{"_type" => "Name", "id" => id}

    test "if x: for {:str} emits `x != \"\"`, drops truthy?/1" do
      ctx = TypeInfer.bind(Context.new(), "s", {:str})
      out = emit_if(name("s"), ctx)
      assert out =~ ~s(s != "")
      refute out =~ "truthy?"
    end

    test "if x: for {:int} emits `x != 0`" do
      ctx = TypeInfer.bind(Context.new(), "n", {:int})
      out = emit_if(name("n"), ctx)
      assert out =~ "n != 0"
      refute out =~ "truthy?"
    end

    test "if x: for {:float} emits `x != 0.0`" do
      ctx = TypeInfer.bind(Context.new(), "n", {:float})
      out = emit_if(name("n"), ctx)
      assert out =~ "n != 0.0"
      refute out =~ "truthy?"
    end

    test "if x: for {:list, _} emits `not Enum.empty?(x)` (opaque to typer)" do
      ctx = TypeInfer.bind(Context.new(), "xs", {:list, {:int}})
      out = emit_if(name("xs"), ctx)
      assert out =~ "Enum.empty?(xs)"
      refute out =~ "xs == []"
      refute out =~ "xs != []"
    end

    test "if x: for {:tuple, _} emits `tuple_size(x) != 0` (opaque to typer)" do
      ctx = TypeInfer.bind(Context.new(), "t", {:tuple, [{:int}, {:int}]})
      out = emit_if(name("t"), ctx)
      assert out =~ "tuple_size(t) != 0"
      refute out =~ "t == {}"
    end

    test "if x: for {:set} emits `MapSet.size(x) != 0`" do
      ctx = TypeInfer.bind(Context.new(), "s", {:set})
      out = emit_if(name("s"), ctx)
      assert out =~ "MapSet.size(s) != 0"
    end

    test "if x: for {:any} (unknown type) keeps the truthy?/1 wrap" do
      out = emit_if(name("z"), Context.new())
      assert out =~ "truthy?(z)"
    end

    test "if x: for {:bool} elides the wrap (pre-existing behaviour)" do
      ctx = TypeInfer.bind(Context.new(), "b", {:bool})
      out = emit_if(name("b"), ctx)
      refute out =~ "truthy?"
      refute out =~ "== 0"
    end

    test "not x for {:str} emits `x == \"\"`, drops truthy?/1" do
      ctx = TypeInfer.bind(Context.new(), "s", {:str})
      out = emit_unary_not(name("s"), ctx)
      assert out =~ ~s(s == "")
      refute out =~ "truthy?"
    end

    test "not x for {:int} emits `x == 0`" do
      ctx = TypeInfer.bind(Context.new(), "n", {:int})
      out = emit_unary_not(name("n"), ctx)
      assert out =~ "n == 0"
    end

    test "not x for {:list, _} emits `Enum.empty?(x)`" do
      ctx = TypeInfer.bind(Context.new(), "xs", {:list, {:int}})
      out = emit_unary_not(name("xs"), ctx)
      assert out =~ "Enum.empty?(xs)"
      refute out =~ "xs == []"
    end

    test "not x for {:tuple, _} emits `tuple_size(x) == 0`" do
      ctx = TypeInfer.bind(Context.new(), "t", {:tuple, [{:int}]})
      out = emit_unary_not(name("t"), ctx)
      assert out =~ "tuple_size(t) == 0"
    end

    test "not x for {:any} keeps `!truthy?(x)`" do
      out = emit_unary_not(name("z"), Context.new())
      assert out =~ "!truthy?(z)"
    end
  end
end
