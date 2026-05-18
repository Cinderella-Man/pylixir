defmodule Pylixir.Stdlib.BisectTest do
  use ExUnit.Case, async: true

  alias Pylixir.Stdlib.Bisect

  describe "call/4" do
    test "bisect_left routes to py_bisect_left helper" do
      a_ast = {:a, [], nil}
      x_ast = {:x, [], nil}

      assert Bisect.call(["bisect_left"], [a_ast, x_ast], %{}, %{}) ==
               {:ok, {:py_bisect_left, [], [a_ast, x_ast]}}
    end

    test "bisect (no suffix) is an alias for bisect_right (per Python docs §10.2)" do
      a_ast = {:a, [], nil}
      x_ast = {:x, [], nil}

      assert Bisect.call(["bisect"], [a_ast, x_ast], %{}, %{}) ==
               {:ok, {:py_bisect_right, [], [a_ast, x_ast]}}
    end

    test "bisect_right routes to py_bisect_right helper" do
      a_ast = {:a, [], nil}
      x_ast = {:x, [], nil}

      assert Bisect.call(["bisect_right"], [a_ast, x_ast], %{}, %{}) ==
               {:ok, {:py_bisect_right, [], [a_ast, x_ast]}}
    end

    test "3-arg form (lo only) routes to the 3-arg helper variant" do
      a = {:a, [], nil}
      x = {:x, [], nil}
      lo = {:lo, [], nil}

      assert Bisect.call(["bisect_left"], [a, x, lo], %{}, %{}) ==
               {:ok, {:py_bisect_left, [], [a, x, lo]}}

      assert Bisect.call(["bisect_right"], [a, x, lo], %{}, %{}) ==
               {:ok, {:py_bisect_right, [], [a, x, lo]}}

      assert Bisect.call(["bisect"], [a, x, lo], %{}, %{}) ==
               {:ok, {:py_bisect_right, [], [a, x, lo]}}
    end

    test "unknown call returns :no_clause" do
      assert Bisect.call(["insort_left"], [], %{}, %{}) == :no_clause
    end
  end

  describe "runtime helpers (direct)" do
    alias Pylixir.RuntimeHelpers, as: H

    test "py_bisect_left — leftmost insertion point for equal values" do
      assert H.py_bisect_left([1, 3, 5, 7, 9], 4) == 2
      assert H.py_bisect_left([1, 3, 5, 7, 9], 5) == 2
      assert H.py_bisect_left([1, 3, 5, 7, 9], 0) == 0
      assert H.py_bisect_left([1, 3, 5, 7, 9], 100) == 5
    end

    test "py_bisect_right — rightmost insertion point for equal values" do
      assert H.py_bisect_right([1, 3, 5, 7, 9], 5) == 3
      assert H.py_bisect_right([1, 3, 5, 5, 9], 5) == 4
    end

    test "3-arg variant defaults hi to len(list)" do
      a = [1, 3, 5, 7, 9, 11, 13]
      assert H.py_bisect_left(a, 7, 2) == 3
      assert H.py_bisect_right(a, 7, 2) == 4
      assert H.py_bisect_left(a, 100, 2) == 7
    end
  end
end
