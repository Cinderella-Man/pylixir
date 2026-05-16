defmodule Pylixir.LoweringTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Lowering, UnsupportedNodeError}

  # The originating Python AST node — its _type/lineno/col_offset feed
  # the raised UnsupportedNodeError.
  defp py_node(type) when is_binary(type),
    do: %{"_type" => type, "lineno" => 7, "col_offset" => 3}

  describe "dispatch/4" do
    test "{:ok, ast} returns {ast, context} unchanged" do
      ctx = %{some: :state}
      ast = {:hello, [], [1, 2]}

      assert Lowering.dispatch({:ok, ast}, "unused hint", py_node("Call"), ctx) == {ast, ctx}
    end

    test "{:error, hint} raises UnsupportedNodeError with that hint" do
      err =
        assert_raise UnsupportedNodeError, fn ->
          Lowering.dispatch({:error, "math.inf has no Elixir equivalent"}, "ignored", py_node("Attribute"), %{})
        end

      assert err.node_type == "Attribute"
      assert err.hint == "math.inf has no Elixir equivalent"
      assert err.lineno == 7
      assert err.col_offset == 3
    end

    test ":no_clause raises UnsupportedNodeError with the caller-supplied hint" do
      err =
        assert_raise UnsupportedNodeError, fn ->
          Lowering.dispatch(:no_clause, "sys.foo.bar is not supported", py_node("Call"), %{})
        end

      assert err.node_type == "Call"
      assert err.hint == "sys.foo.bar is not supported"
    end

    test "missing _type in node crashes loudly (no silent fallback)" do
      # Defensive: every Python AST node carries _type. If the caller
      # forgot to pass a real node, fail visibly instead of swallowing.
      assert_raise KeyError, fn ->
        Lowering.dispatch({:error, "x"}, "y", %{}, %{})
      end
    end
  end
end
