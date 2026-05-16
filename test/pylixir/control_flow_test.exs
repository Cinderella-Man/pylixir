defmodule Pylixir.ControlFlowTest do
  use ExUnit.Case, async: true

  alias Pylixir.ControlFlow

  describe "throw constructors emit the documented tuple shape" do
    test "throw_return wraps the value in {:pylixir_return, _}" do
      assert ControlFlow.throw_return(42) == {:throw, [], [{:pylixir_return, 42}]}
    end

    test "throw_break wraps the payload in {:pylixir_break, _}" do
      payload = {:acc, [], nil}
      assert ControlFlow.throw_break(payload) == {:throw, [], [{:pylixir_break, payload}]}
    end

    test "throw_continue wraps the payload in {:pylixir_continue, _}" do
      payload = {:acc, [], nil}
      assert ControlFlow.throw_continue(payload) == {:throw, [], [{:pylixir_continue, payload}]}
    end

    test "throw_exit wraps the code in {:pylixir_exit, _}" do
      assert ControlFlow.throw_exit(0) == {:throw, [], [{:pylixir_exit, 0}]}
      assert ControlFlow.throw_exit(42) == {:throw, [], [{:pylixir_exit, 42}]}
    end
  end

  describe "catch-clause constructors emit a `:->` clause matching the throw" do
    test "catch_return matches the same tuple shape as throw_return" do
      val = {:val, [], nil}
      body = {:do_something, [], []}

      assert ControlFlow.catch_return(val, body) ==
               {:->, [], [[:throw, {:pylixir_return, val}], body]}
    end

    test "catch_break matches the same tuple shape as throw_break" do
      acc = {:acc, [], nil}

      assert ControlFlow.catch_break(acc, acc) ==
               {:->, [], [[:throw, {:pylixir_break, acc}], acc]}
    end

    test "catch_continue matches the same tuple shape as throw_continue" do
      acc = {:acc, [], nil}
      recurse = {:recurse, [], []}

      assert ControlFlow.catch_continue(acc, recurse) ==
               {:->, [], [[:throw, {:pylixir_continue, acc}], recurse]}
    end

    test "catch_exit matches the same tuple shape as throw_exit" do
      code = {:code, [], nil}

      assert ControlFlow.catch_exit(code, code) ==
               {:->, [], [[:throw, {:pylixir_exit, code}], code]}
    end
  end

  # Pin the throw/catch invariant: a throw's payload tuple shape must
  # match the corresponding catch's pattern. This is what the module
  # exists to enforce — if a future tuple-shape change broke the pairing,
  # this test fails next to whichever side regressed.
  describe "throw/catch pairing — payload shape must agree" do
    test "return: catch's pattern matches throw's payload" do
      v = {:v, [], nil}
      {:throw, _, [throw_payload]} = ControlFlow.throw_return(v)
      {:->, _, [[:throw, catch_pattern], _]} = ControlFlow.catch_return(v, v)
      assert throw_payload == catch_pattern
    end

    test "break: catch's pattern matches throw's payload" do
      p = {:p, [], nil}
      {:throw, _, [throw_payload]} = ControlFlow.throw_break(p)
      {:->, _, [[:throw, catch_pattern], _]} = ControlFlow.catch_break(p, p)
      assert throw_payload == catch_pattern
    end

    test "continue: catch's pattern matches throw's payload" do
      p = {:p, [], nil}
      {:throw, _, [throw_payload]} = ControlFlow.throw_continue(p)
      {:->, _, [[:throw, catch_pattern], _]} = ControlFlow.catch_continue(p, p)
      assert throw_payload == catch_pattern
    end

    test "exit: catch's pattern matches throw's payload" do
      c = {:c, [], nil}
      {:throw, _, [throw_payload]} = ControlFlow.throw_exit(c)
      {:->, _, [[:throw, catch_pattern], _]} = ControlFlow.catch_exit(c, c)
      assert throw_payload == catch_pattern
    end
  end
end
