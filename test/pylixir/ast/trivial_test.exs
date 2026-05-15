defmodule Pylixir.AST.TrivialTest do
  use ExUnit.Case, async: true

  alias Pylixir.AST.Trivial

  describe "trivial?/1" do
    test "Constant is trivial" do
      assert Trivial.trivial?(%{"_type" => "Constant", "value" => 1})
    end

    test "Name is trivial" do
      assert Trivial.trivial?(%{"_type" => "Name", "id" => "x"})
    end

    test "Attribute on a trivial value is trivial (single dot)" do
      assert Trivial.trivial?(%{
               "_type" => "Attribute",
               "value" => %{"_type" => "Name", "id" => "obj"},
               "attr" => "x"
             })
    end

    test "Attribute on an attribute is trivial (recursive)" do
      assert Trivial.trivial?(%{
               "_type" => "Attribute",
               "value" => %{
                 "_type" => "Attribute",
                 "value" => %{"_type" => "Name", "id" => "a"},
                 "attr" => "b"
               },
               "attr" => "c"
             })
    end

    test "Call is non-trivial" do
      refute Trivial.trivial?(%{"_type" => "Call"})
    end

    test "BinOp is non-trivial" do
      refute Trivial.trivial?(%{"_type" => "BinOp"})
    end

    test "Subscript is non-trivial" do
      refute Trivial.trivial?(%{"_type" => "Subscript"})
    end

    test "Attribute on a Call value is non-trivial (the Call has to run)" do
      refute Trivial.trivial?(%{
               "_type" => "Attribute",
               "value" => %{"_type" => "Call"},
               "attr" => "x"
             })
    end
  end
end
