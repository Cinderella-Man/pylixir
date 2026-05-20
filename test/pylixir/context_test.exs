defmodule Pylixir.ContextTest do
  use ExUnit.Case, async: true

  alias Pylixir.Context

  describe "new/1" do
    test "starts with one empty scope and default counters" do
      ctx = Context.new()

      assert [first | _] = ctx.scopes
      assert MapSet.size(first) == 0
      assert ctx.while_counter == 0
      assert ctx.loop_nesting == 0
      assert MapSet.size(ctx.known_functions) == 0
    end

    test "accepts pre-collected function names" do
      names = MapSet.new(["fib", "main"])
      ctx = Context.new(names)

      assert ctx.known_functions == names
    end

    test "initializes the single-evaluation temp counter to zero" do
      assert Context.new().temp_counter == 0
    end

    test "initializes module_attrs to an empty MapSet" do
      ctx = Context.new()

      assert MapSet.size(ctx.module_attrs) == 0
    end

    test "starts at :module_top so the first FunctionDef encountered is a top-level def" do
      assert Context.new().def_position == :module_top
    end

    test "freezable_names defaults to an empty MapSet" do
      assert Context.new().freezable_names == MapSet.new()
    end
  end
end
