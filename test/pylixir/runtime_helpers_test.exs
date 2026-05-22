defmodule Pylixir.RuntimeHelpersTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Pylixir.RuntimeHelpers, as: H

  describe "py_stdin_readline/0" do
    test "returns one line including the trailing newline" do
      assert capture_io("hello\nworld\n", fn ->
               send(self(), {:line, H.py_stdin_readline()})
             end)

      assert_received {:line, "hello\n"}
    end

    test "returns empty string at EOF (not :eof, no raise)" do
      assert capture_io("", fn ->
               send(self(), {:line, H.py_stdin_readline()})
             end)

      assert_received {:line, ""}
    end
  end

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

  describe "py_str_index/2 — receiver-polymorphic .index()" do
    # Pylixir's `.index()` method always emits `py_str_index/2`. The
    # helper must therefore handle every Python receiver type that
    # supports `.index()`: str (substring search), list (equality),
    # tuple (equality). A non-string receiver used to crash with
    # `FunctionClauseError in String.split/3` because the binary-only
    # path called `String.split(receiver, _, parts: 2)`.

    test "string receiver: substring index, matching str.index()" do
      assert H.py_str_index("hello world", "world") == 6
      assert H.py_str_index("hello", "h") == 0
    end

    test "string receiver: missing substring raises" do
      assert_raise RuntimeError, "substring not found", fn ->
        H.py_str_index("hello", "z")
      end
    end

    test "list receiver: returns the index of the first equal element" do
      assert H.py_str_index([10, 20, 30], 20) == 1
      assert H.py_str_index([10, 20, 30], 10) == 0
      assert H.py_str_index([:a, :b, :c], :c) == 2
    end

    test "list receiver: missing element raises ValueError-ish" do
      assert_raise RuntimeError, ~r/is not in list/, fn ->
        H.py_str_index([1, 2, 3], 99)
      end
    end

    test "tuple receiver: behaves like list.index" do
      assert H.py_str_index({10, 20, 30}, 30) == 2
      assert H.py_str_index({"a", "b"}, "b") == 1
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

  describe "py_sub/2 — Counter subtraction (map - map)" do
    # `collections.Counter` lowers to a plain frequency map. Python's
    # `Counter - Counter` subtracts counts and KEEPS ONLY positive
    # results (negative/zero counts are dropped). Regular dict
    # subtraction is a TypeError in Python, so a map-minus-map at
    # runtime is unambiguously a Counter op. Without this clause
    # py_sub fell through to `a - b` and crashed with ArithmeticError
    # (eval-corpus seed_1726 / seed_17225).
    test "keeps only positive counts" do
      a = %{1 => 3, 2 => 1, 3 => 2}
      b = %{1 => 1, 2 => 2, 4 => 5}
      # 1: 3-1=2 (keep), 2: 1-2=-1 (drop), 3: 2-0=2 (keep), 4: only in b (ignored)
      assert H.py_sub(a, b) == %{1 => 2, 3 => 2}
    end

    test "disjoint keys: left counts pass through, right ignored" do
      assert H.py_sub(%{"x" => 4}, %{"y" => 9}) == %{"x" => 4}
    end

    test "identical counters → empty" do
      assert H.py_sub(%{1 => 2, 2 => 3}, %{1 => 2, 2 => 3}) == %{}
    end

    test "empty minus empty → empty" do
      assert H.py_sub(%{}, %{}) == %{}
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

    test "string left operand applies Python %-formatting" do
      assert H.py_mod("hello %s", "world") == "hello world"
      assert H.py_mod("%d + %d = %d", {2, 3, 5}) == "2 + 3 = 5"
      assert H.py_mod("%05d", 42) == "00042"
      assert H.py_mod("%.2f", 3.14159) == "3.14"
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

  describe "py_alist_* — frozen-list (alist) primitives" do
    test "py_alist_new wraps an enumerable as a tagged tuple of its elements" do
      assert H.py_alist_new([1, 2, 3]) == {:py_alist, {1, 2, 3}}
      assert H.py_alist_new([]) == {:py_alist, {}}
      assert H.py_alist_new(1..3) == {:py_alist, {1, 2, 3}}
    end

    test "py_getitem on an alist is O(1)-shaped and respects Python indexing" do
      a = H.py_alist_new(Enum.to_list(0..999))
      assert H.py_getitem(a, 0) == 0
      assert H.py_getitem(a, 999) == 999
      assert H.py_getitem(a, -1) == 999
      assert H.py_getitem(a, -1000) == 0
    end

    test "py_getitem returns nil for out-of-range indices (matches existing list behaviour)" do
      a = H.py_alist_new([10, 20, 30])
      assert H.py_getitem(a, 5) == nil
      assert H.py_getitem(a, -4) == nil
    end

    # Regression (eval --skip 200 --limit 100, seed_1720--799b5d32):
    # nested defaultdict subscripts (`char_dict[c][prev_sum]`) lower
    # to chained `py_getitem` calls. When the OUTER dict has no entry
    # for `c`, the outer lookup returns `nil` (Pylixir's chosen
    # missing-key semantics — see the map clause comment) and the
    # next `py_getitem(nil, prev_sum)` had no matching function clause,
    # crashing with FunctionClauseError. Returning `nil` propagates
    # cleanly through Pylixir's `nil`-as-additive-identity helpers
    # (e.g. `py_add(nil, n) == n`).
    test "py_getitem on nil returns nil (chained-subscript missing-key path)" do
      assert H.py_getitem(nil, "anything") == nil
      assert H.py_getitem(nil, 0) == nil
    end

    # Sibling regression: `char_dict[c][k] += 1` lowers to
    # `py_setitem(py_getitem(char_dict, c), k, ...)`. When `c` is
    # missing, the inner `py_getitem` now returns nil (per the test
    # above), so `py_setitem` receives nil. Materialise as a fresh
    # map containing just `k => v` — the outer `py_setitem` then
    # binds that map at key `c`, mirroring Python's defaultdict
    # auto-creation.
    test "py_setitem on nil materialises a fresh map for nested-subscript writes" do
      assert H.py_setitem(nil, "x", 1) == %{"x" => 1}
      assert H.py_setitem(nil, 0, 42) == %{0 => 42}
    end

    # Regression (eval --skip 200 --limit 100, seed_1720--3aa6d273):
    # `char_indices[c].append(idx)` lowers to
    # `py_setitem(coll, c, py_getitem(coll, c) ++ [idx])`. With a
    # missing `c`, `py_getitem` returns nil and the raw `++` operator
    # blows up with ArgumentError. A dedicated `py_append/2` helper
    # treats nil as an empty list — matches Python's
    # `defaultdict(list)` auto-creation.
    test "py_append on nil creates a new single-element list" do
      assert H.py_append(nil, 1) == [1]
      assert H.py_append(nil, "x") == ["x"]
    end

    test "py_append on a plain list appends at the tail (preserves order)" do
      assert H.py_append([1, 2], 3) == [1, 2, 3]
      assert H.py_append([], 1) == [1]
    end

    test "py_len returns tuple_size; does not accidentally hit the is_tuple clause" do
      a = H.py_alist_new([:a, :b, :c, :d])
      assert H.py_len(a) == 4
      assert H.py_len(H.py_alist_new([])) == 0
    end

    test "py_in checks membership against the unwrapped element list" do
      a = H.py_alist_new([1, 2, 3])
      assert H.py_in(2, a)
      refute H.py_in(99, a)
    end

    test "py_iter_to_list unwraps an alist back to a regular list" do
      assert H.py_iter_to_list(H.py_alist_new([1, 2, 3])) == [1, 2, 3]
    end

    test "py_slice on an alist returns a regular Elixir list (Python: slice of a list is a list)" do
      a = H.py_alist_new([0, 1, 2, 3, 4, 5])
      assert H.py_slice(a, 1, 4, nil) == [1, 2, 3]
      assert H.py_slice(a, 0, 6, 2) == [0, 2, 4]
      assert H.py_slice(a, nil, nil, -1) == [5, 4, 3, 2, 1, 0]
    end

    test "py_str / py_repr render an alist as list-style `[...]`, not tuple-style `(...)`" do
      a = H.py_alist_new([1, 2, 3])
      assert H.py_str(a) == "[1, 2, 3]"
      assert H.py_repr(a) == "[1, 2, 3]"
    end

    test "py_eq normalises both sides through py_iter_to_list" do
      a = H.py_alist_new([1, 2, 3])
      assert H.py_eq(a, [1, 2, 3])
      assert H.py_eq([1, 2, 3], a)
      assert H.py_eq(a, a)
      refute H.py_eq(a, [1, 2, 99])
    end

    test "py_eq stays on plain `==` when neither side is alist" do
      assert H.py_eq(1, 1)
      assert H.py_eq("foo", "foo")
      refute H.py_eq([1, 2], [1, 2, 3])
    end

    test "indexed read is fast on a 100k-element alist (O(1) per read)" do
      a = H.py_alist_new(Enum.to_list(0..99_999))
      # 100k random-ish reads — should be effectively instant. Just
      # assert correctness; the implicit timing guard is the test
      # finishing within ExUnit's default timeout.
      assert Enum.all?(0..99_999//7, fn i -> H.py_getitem(a, i) == i end)
    end

    test "py_slice on a 100k-element list is O(n), not O(n²)" do
      # eval-corpus `seed_13048` shape: `data = sys.stdin.read().split();
      # L = list(map(int, data[1:n+1]))`. A naive
      # `Enum.map(indices, &Enum.at(list, &1))` is O(n²) — `Enum.at`
      # traverses from the head every call. For n=100k that's ~5s with
      # `Enum.at`; the linear lowering (`List.to_tuple` once, then
      # `elem/2`) finishes in tens of milliseconds.
      data = Enum.map(0..99_999, &Integer.to_string/1)
      {time_us, sliced} = :timer.tc(fn -> H.py_slice(data, 1, 100_000, nil) end)
      assert length(sliced) == 99_999
      assert hd(sliced) == "1"
      assert List.last(sliced) == "99999"

      elapsed_ms = div(time_us, 1000)

      assert elapsed_ms < 500,
             "py_slice on 100k-list took #{elapsed_ms}ms — expected well under 500ms (O(n²) fallback detected)"
    end

    test "py_slice with negative step on a list stays linear" do
      data = Enum.to_list(0..49_999)
      {time_us, sliced} = :timer.tc(fn -> H.py_slice(data, nil, nil, -1) end)
      assert length(sliced) == 50_000
      assert hd(sliced) == 49_999
      assert List.last(sliced) == 0

      elapsed_ms = div(time_us, 1000)

      assert elapsed_ms < 500,
             "py_slice (step=-1) on 50k-list took #{elapsed_ms}ms — expected well under 500ms"
    end

    test "py_slice on a 100k-char binary is O(n), not O(n²)" do
      # eval-corpus `seed_16487` shape: string-rotation comparison
      # `start[t:] + start[:t]` in a loop over n. A naive
      # `Enum.map_join(indices, "", &String.at(s, &1))` is O(n²) per
      # slice (String.at is O(index) on a UTF-8 binary), making the
      # whole loop O(n³). Linearizing the slice (graphemes → tuple →
      # elem) brings each slice to O(n).
      s = String.duplicate("ab", 50_000)
      {time_us, sliced} = :timer.tc(fn -> H.py_slice(s, 1, 100_000, nil) end)
      assert byte_size(sliced) == 99_999
      assert String.first(sliced) == "b"

      elapsed_ms = div(time_us, 1000)

      assert elapsed_ms < 500,
             "py_slice on 100k-char binary took #{elapsed_ms}ms — expected well under 500ms (O(n²) String.at fallback)"
    end

    test "py_slice on a binary preserves Python semantics (negative / step)" do
      s = "abcdef"
      assert H.py_slice(s, 1, 4, nil) == "bcd"
      assert H.py_slice(s, nil, nil, -1) == "fedcba"
      assert H.py_slice(s, 0, 6, 2) == "ace"
      assert H.py_slice(s, -2, nil, nil) == "ef"
    end
  end

  describe "py_copy/1 — shallow copy for `.copy()` dispatch" do
    test "list copy is equal to source; mutating the copy doesn't affect the original" do
      xs = [1, 2, 3]
      ys = H.py_copy(xs)
      assert ys == xs
      ys2 = List.delete(ys, 2)
      assert xs == [1, 2, 3]
      assert ys2 == [1, 3]
    end

    test "map copy preserves entries; mutating the copy doesn't affect the original" do
      d = %{"a" => 1, "b" => 2}
      e = H.py_copy(d)
      assert e == d
      e2 = Map.put(e, "a", 99)
      assert d == %{"a" => 1, "b" => 2}
      assert e2 == %{"a" => 99, "b" => 2}
    end

    test "MapSet copy preserves elements; mutating the copy doesn't affect the original" do
      s = MapSet.new([1, 2, 3])
      t = H.py_copy(s)
      assert t == s
      t2 = MapSet.delete(t, 2)
      assert s == MapSet.new([1, 2, 3])
      assert t2 == MapSet.new([1, 3])
    end

    test "alist copy unwraps to a fresh regular list" do
      a = H.py_alist_new([1, 2, 3])
      copy = H.py_copy(a)
      assert copy == [1, 2, 3]
      assert is_list(copy)
    end
  end
end
