defmodule Pylixir.RuntimeHelpersTest do
  use ExUnit.Case, async: true

  alias Pylixir.RuntimeHelpers, as: H

  describe "truthy?/1 — Python truthiness (RFC §6.3)" do
    test "Python falsy: nil, false, 0, 0.0, empty string, empty list" do
      refute H.truthy?(nil)
      refute H.truthy?(false)
      refute H.truthy?(0)
      refute H.truthy?(+0.0)
      refute H.truthy?(-0.0)
      refute H.truthy?("")
      refute H.truthy?([])
    end

    test "empty map is falsy" do
      refute H.truthy?(%{})
    end

    test "empty MapSet is falsy (MapSet clause must precede the is_map clause)" do
      refute H.truthy?(MapSet.new())
    end

    test "non-empty values are truthy" do
      assert H.truthy?(1)
      assert H.truthy?(0.1)
      assert H.truthy?("x")
      assert H.truthy?([0])
      assert H.truthy?(%{a: 1})
      assert H.truthy?(MapSet.new([1]))
    end
  end

  describe "py_add/2 — type-dispatched +" do
    test "ints add normally" do
      assert H.py_add(1, 2) == 3
    end

    test "strings concatenate (Python's str + str)" do
      assert H.py_add("a", "b") == "ab"
    end

    test "lists concatenate (Python's list + list)" do
      assert H.py_add([1, 2], [3]) == [1, 2, 3]
    end

    test "booleans are treated as ints (Python's True + True == 2)" do
      assert H.py_add(true, true) == 2
      assert H.py_add(true, 1) == 2
      assert H.py_add(false, 5) == 5
    end
  end

  describe "py_str/1 — Python str() representation (RFC §6.7)" do
    test "True/False/None reprs use Python capitalization" do
      assert H.py_str(true) == "True"
      assert H.py_str(false) == "False"
      assert H.py_str(nil) == "None"
    end

    test "integers and floats stringify naturally" do
      assert H.py_str(42) == "42"
    end

    test "lists use bracket + comma-space format with reprs of elements" do
      assert H.py_str([1, 2, 3]) == "[1, 2, 3]"
      assert H.py_str(["a", "b"]) == "['a', 'b']"
    end

    test "tuples use paren format; single-element gets trailing comma" do
      assert H.py_str({1, 2}) == "(1, 2)"
      assert H.py_str({42}) == "(42,)"
    end
  end

  describe "py_round/1,2 — banker's rounding (RFC §6.14)" do
    test "half-to-even on .5 boundaries" do
      assert H.py_round(0.5) == 0
      assert H.py_round(1.5) == 2
      assert H.py_round(2.5) == 2
      assert H.py_round(3.5) == 4
      assert H.py_round(-0.5) == 0
      assert H.py_round(-1.5) == -2
    end

    test "non-half values round normally" do
      assert H.py_round(0.4) == 0
      assert H.py_round(0.6) == 1
      assert H.py_round(-0.6) == -1
    end

    test "integers pass through" do
      assert H.py_round(5) == 5
      assert H.py_round(-3) == -3
    end

    test "two-arg form rounds to decimal places" do
      assert_in_delta H.py_round(3.14159, 2), 3.14, 1.0e-9
    end
  end

  describe "py_hex/1 — Python hex() format (RFC §6.7-adjacent)" do
    test "positive numbers use 0x prefix, lowercase" do
      assert H.py_hex(255) == "0xff"
      assert H.py_hex(0) == "0x0"
    end

    test "negative numbers use -0x prefix" do
      assert H.py_hex(-255) == "-0xff"
    end
  end

  describe "py_str_count/2 — Python str.count semantics (RFC §6.20-adjacent)" do
    test "counts non-overlapping occurrences" do
      assert H.py_str_count("hello", "l") == 2
      assert H.py_str_count("abcabc", "b") == 2
    end

    test "empty separator returns len + 1 (Python quirk)" do
      assert H.py_str_count("abc", "") == 4
    end

    test "no match returns 0" do
      assert H.py_str_count("hello", "z") == 0
    end
  end

  describe "py_floor_div/2 — Python `//` (RFC §6.1)" do
    test "int // int rounds toward negative infinity (not toward zero)" do
      assert H.py_floor_div(7, 2) == 3
      assert H.py_floor_div(-7, 2) == -4
      assert H.py_floor_div(7, -2) == -4
    end

    test "float operands return float and still floor" do
      assert H.py_floor_div(7.0, 2) == 3.0
      assert H.py_floor_div(-7.0, 2.0) == -4.0
    end
  end

  describe "py_mod/2 — Python `%` (RFC §6.2)" do
    test "int % int matches Python floor-modulo (sign of result follows divisor)" do
      assert H.py_mod(7, 2) == 1
      assert H.py_mod(-7, 2) == 1
      assert H.py_mod(7, -2) == -1
    end

    test "float operands return float floor-modulo" do
      assert_in_delta H.py_mod(7.5, 2.0), 1.5, 1.0e-9
    end

    test "string left operand raises with the Python %-formatting hint" do
      err =
        assert_raise ArgumentError, fn ->
          H.py_mod("hello %s", "world")
        end

      assert err.message =~ "%-string formatting"
    end
  end

  describe "boolean arithmetic (RFC §6.11)" do
    test "True + True == 2; True * 5 == 5" do
      assert H.py_add(true, true) == 2
      assert H.py_mult(true, 5) == 5
      assert H.py_abs(true) == 1
      assert H.py_abs(false) == 0
    end
  end
end
