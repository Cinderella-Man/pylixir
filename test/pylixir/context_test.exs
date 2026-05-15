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
  end
end
