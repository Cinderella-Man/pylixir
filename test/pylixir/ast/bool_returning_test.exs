defmodule Pylixir.AST.BoolReturningTest do
  use ExUnit.Case, async: true

  alias Pylixir.AST.BoolReturning

  describe "bool_returning?/1" do
    test "Compare is bool-returning" do
      assert BoolReturning.bool_returning?(%{"_type" => "Compare"})
    end

    test "BoolOp is NOT bool-returning (returns one of the operands)" do
      refute BoolReturning.bool_returning?(%{"_type" => "BoolOp"})
    end

    test "Name is NOT bool-returning (unknown runtime type)" do
      refute BoolReturning.bool_returning?(%{"_type" => "Name"})
    end

    test "Constant of a bool value is NOT bool-returning (predicate is structural)" do
      # Could be tightened in the future, but staying conservative for MVP.
      refute BoolReturning.bool_returning?(%{"_type" => "Constant", "value" => true})
    end
  end
end
