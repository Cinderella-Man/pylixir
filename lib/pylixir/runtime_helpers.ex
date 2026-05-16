defmodule Pylixir.RuntimeHelpers do
  @moduledoc """
  Canonical source-of-truth for Python-runtime helpers, mirroring RFC §9.

  Two consumers:

    * `Pylixir.HelpersCodegen` reads this file at Pylixir's compile time,
      slices between the sentinel comments below, and bakes the resulting
      text into a `@helpers_source` constant. T05's `Module` clause splices
      that text into the generated `TranslatedCode` module so every output
      is self-contained.
    * ExUnit can call helpers directly via `Pylixir.RuntimeHelpers.py_add/2`
      etc. — verifying behaviour without a full transpile-and-eval cycle.

  Helpers are emitted as public `def`s, not `defp`, by deliberate choice:
  unused public functions never trigger a compiler warning, while unused
  private functions do. The plan deferred tree-shaking, so most output
  modules will include helpers that are never called — without `def`, every
  generated module would compile with a wall of unused-function warnings
  that would fail T04b's `diagnostics == []` assertion.

  Two sentinel comments delimit the region that `HelpersCodegen` extracts
  (search this file for "HELPERS" followed by START or END). Do not remove
  or reword them. Everything between them lands in generated output
  verbatim.
  """

  # --- HELPERS START ---

  # === Truthiness ===
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(0), do: false
  def truthy?(+0.0), do: false
  def truthy?(-0.0), do: false
  def truthy?(""), do: false
  def truthy?([]), do: false
  def truthy?(%MapSet{} = s), do: MapSet.size(s) > 0
  def truthy?(map) when is_map(map) and map_size(map) == 0, do: false
  def truthy?(_), do: true

  # === Arithmetic with type dispatch ===
  def py_bool_to_int(true), do: 1
  def py_bool_to_int(false), do: 0
  def py_bool_to_int(x), do: x

  # `nil`-tolerant clauses enable the `defaultdict(int)` idiom — see
  # the comment on `py_getitem` for maps. `nil` acts as the additive
  # identity: `nil + n = n`, `s + nil = s`. Without this, `d[k] += 1`
  # on a missing key would crash with `nil + 1` ArithmeticError.
  def py_add(nil, b), do: b
  def py_add(a, nil), do: a

  def py_add(a, b) when is_boolean(a), do: py_add(py_bool_to_int(a), b)
  def py_add(a, b) when is_boolean(b), do: py_add(a, py_bool_to_int(b))
  def py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
  def py_add(a, b) when is_number(a) and is_number(b), do: a + b
  def py_add(a, b) when is_list(a) and is_list(b), do: a ++ b
  def py_add(a, b), do: a + b

  # RFC §6.11 — booleans coerce to ints in arithmetic.
  def py_sub(a, b) when is_boolean(a), do: py_sub(py_bool_to_int(a), b)
  def py_sub(a, b) when is_boolean(b), do: py_sub(a, py_bool_to_int(b))
  def py_sub(a, b), do: a - b

  def py_div(a, b) when is_boolean(a), do: py_div(py_bool_to_int(a), b)
  def py_div(a, b) when is_boolean(b), do: py_div(a, py_bool_to_int(b))
  def py_div(a, b), do: a / b

  def py_mult(a, b) when is_boolean(a), do: py_mult(py_bool_to_int(a), b)
  def py_mult(a, b) when is_boolean(b), do: py_mult(a, py_bool_to_int(b))

  def py_mult(a, b) when is_binary(a) and is_integer(b) and b > 0,
    do: String.duplicate(a, b)

  def py_mult(a, b) when is_binary(a) and is_integer(b), do: ""

  def py_mult(a, b) when is_integer(a) and is_binary(b) and a > 0,
    do: String.duplicate(b, a)

  def py_mult(a, b) when is_integer(a) and is_binary(b), do: ""

  def py_mult(a, b) when is_list(a) and is_integer(b) and b > 0,
    do: List.duplicate(a, b) |> Enum.concat()

  def py_mult(a, b) when is_list(a) and is_integer(b), do: []

  def py_mult(a, b) when is_integer(a) and is_list(b) and a > 0,
    do: List.duplicate(b, a) |> Enum.concat()

  def py_mult(a, b) when is_integer(a) and is_list(b), do: []
  def py_mult(a, b), do: a * b

  def py_pow(base, exp) when is_integer(base) and is_integer(exp) and exp >= 0,
    do: Integer.pow(base, exp)

  def py_pow(base, exp), do: :math.pow(base, exp)

  # Python's 3-arg `pow(base, exp, mod)` — modular exponentiation.
  # Uses Erlang's :crypto.mod_pow (square-and-multiply, suitable for
  # large exponents used in number-theoretic code like modular inverses
  # via Fermat's little theorem).
  def py_pow_mod(base, exp, mod)
      when is_integer(base) and is_integer(exp) and is_integer(mod) and exp >= 0 and mod > 0 do
    :crypto.mod_pow(base, exp, mod) |> :crypto.bytes_to_integer()
  end

  # Python's `//` floor-divides; sign follows the divisor for negatives.
  # Integer.floor_div/2 matches Python for int operands; for mixed/float
  # operands, `:math.floor(a/b)` matches Python (returns float).
  def py_floor_div(a, b) when is_integer(a) and is_integer(b), do: Integer.floor_div(a, b)
  def py_floor_div(a, b) when is_number(a) and is_number(b), do: :math.floor(a / b)

  # Python's `%` is dual-meaning: numeric modulo (floor-modulo, sign
  # follows divisor) and string %-formatting. The helper dispatches at
  # runtime: integers → Integer.mod/2; binary left → raise with a hint
  # naming the unsupported feature rather than letting an opaque
  # FunctionClauseError leak through.
  def py_mod(a, _b) when is_binary(a),
    do:
      raise(ArgumentError,
        message:
          "Python %-string formatting (`'%s' % name`) is not supported; use string concatenation"
      )

  def py_mod(a, b) when is_integer(a) and is_integer(b), do: Integer.mod(a, b)
  def py_mod(a, b) when is_number(a) and is_number(b), do: a - b * :math.floor(a / b)

  # === Collection access ===
  def py_len(x) when is_list(x), do: length(x)
  def py_len(x) when is_binary(x), do: String.length(x)
  def py_len(%MapSet{} = x), do: MapSet.size(x)
  def py_len(x) when is_map(x), do: map_size(x)
  def py_len(x) when is_tuple(x), do: tuple_size(x)

  # Python slice [start:stop:step] with full semantics: negative indices
  # wrap from len; nil bounds default to 0/len (or len-1/-1 for negative
  # step); negative step iterates backward. Works on lists, binaries, and
  # tuples. See RFC §6.18.
  def py_slice(coll, start, stop, step) do
    step_v = step || 1
    len = py_len(coll)

    {start_i, stop_i} = py_slice_bounds(start, stop, step_v, len)
    indices = py_slice_indices(start_i, stop_i, step_v)

    cond do
      is_list(coll) -> Enum.map(indices, &Enum.at(coll, &1))
      is_binary(coll) -> Enum.map_join(indices, "", &String.at(coll, &1))
      is_tuple(coll) -> indices |> Enum.map(&elem(coll, &1)) |> List.to_tuple()
    end
  end

  def py_slice_bounds(start, stop, step, len) do
    if step > 0 do
      s = if start == nil, do: 0, else: py_slice_clamp_pos(start, len)
      e = if stop == nil, do: len, else: py_slice_clamp_pos(stop, len)
      {s, e}
    else
      s = if start == nil, do: len - 1, else: py_slice_clamp_neg(start, len)
      e = if stop == nil, do: -1, else: py_slice_clamp_neg(stop, len)
      {s, e}
    end
  end

  def py_slice_clamp_pos(i, len) when i < 0, do: max(0, len + i)
  def py_slice_clamp_pos(i, len), do: min(i, len)

  def py_slice_clamp_neg(i, len) when i < 0, do: max(-1, len + i)
  def py_slice_clamp_neg(i, len) when i >= len, do: len - 1
  def py_slice_clamp_neg(i, _len), do: i

  def py_slice_indices(start, stop, step) when step > 0 do
    Stream.iterate(start, &(&1 + step)) |> Enum.take_while(&(&1 < stop))
  end

  def py_slice_indices(start, stop, step) do
    Stream.iterate(start, &(&1 + step)) |> Enum.take_while(&(&1 > stop))
  end

  def py_getitem(c, k) when is_list(c), do: Enum.at(c, k)
  def py_getitem(c, k) when is_binary(c), do: String.at(c, k)
  def py_getitem(c, k) when is_tuple(c) and k >= 0, do: elem(c, k)
  def py_getitem(c, k) when is_tuple(c), do: elem(c, tuple_size(c) + k)
  # Maps: return `nil` for missing keys (not `Map.fetch!`/raise). This
  # enables the `defaultdict(int)`-style idiom `d[k] += 1` to work
  # against a regular `%{}` — `py_add(nil, …)` treats `nil` as the
  # additive identity. Trade-off: legitimate missing-key bugs against
  # plain dicts surface later (as `nil` propagating) rather than as
  # an immediate `KeyError`. Python uses `dict.get(k, default)` for
  # the default-aware read, and Pylixir's `.get` clause routes to
  # `Map.get` already — those callers are unaffected.
  def py_getitem(c, k) when is_map(c), do: Map.get(c, k)

  def py_setitem(c, k, v) when is_list(c), do: List.replace_at(c, k, v)
  def py_setitem(c, k, v) when is_map(c), do: Map.put(c, k, v)

  # `del coll[k]` — Python's subscript deletion. Polymorphic on the
  # collection: list → `List.delete_at`, map → `Map.delete`,
  # MapSet → `MapSet.delete`. Pylixir lowers the surrounding
  # `Delete` to `coll = py_delitem(coll, k)`.
  def py_delitem(c, k) when is_list(c), do: List.delete_at(c, k)
  def py_delitem(%MapSet{} = c, k), do: MapSet.delete(c, k)
  def py_delitem(c, k) when is_map(c), do: Map.delete(c, k)

  def py_in(x, c) when is_list(c), do: x in c
  def py_in(x, c) when is_binary(c), do: String.contains?(c, x)
  def py_in(x, %MapSet{} = c), do: MapSet.member?(c, x)
  def py_in(x, c) when is_map(c), do: Map.has_key?(c, x)
  def py_in(x, c) when is_tuple(c), do: py_in(x, Tuple.to_list(c))
  def py_in(x, c), do: Enum.member?(c, x)

  # === Type conversion ===
  def py_int(true), do: 1
  def py_int(false), do: 0
  def py_int(x) when is_float(x), do: trunc(x)
  def py_int(x) when is_integer(x), do: x
  def py_int(x) when is_binary(x), do: String.trim(x) |> String.to_integer()

  def py_float(true), do: 1.0
  def py_float(false), do: 0.0
  def py_float(x) when is_integer(x), do: x / 1
  def py_float(x) when is_float(x), do: x

  def py_float(x) when is_binary(x) do
    trimmed = String.trim(x)

    case String.downcase(trimmed) do
      s when s in ~w[inf +inf -inf infinity +infinity -infinity nan] ->
        raise ArgumentError, "Python float('#{trimmed}') is not supported"

      _ ->
        case Float.parse(trimmed) do
          {f, ""} -> f
          _ -> raise ArgumentError, "could not convert string to float: #{inspect(x)}"
        end
    end
  end

  # === String representation ===
  def py_str(true), do: "True"
  def py_str(false), do: "False"
  def py_str(nil), do: "None"
  def py_str(x) when is_atom(x), do: Atom.to_string(x)
  def py_str(x) when is_list(x), do: py_repr_list(x)
  def py_str(x) when is_tuple(x), do: py_repr_tuple(x)
  def py_str(x) when is_map(x) and not is_struct(x), do: py_repr_map(x)
  def py_str(x), do: to_string(x)

  def py_repr_list(items), do: "[" <> Enum.map_join(items, ", ", &py_repr/1) <> "]"

  def py_repr_tuple(t) do
    items = Tuple.to_list(t)

    case items do
      [single] -> "(" <> py_repr(single) <> ",)"
      _ -> "(" <> Enum.map_join(items, ", ", &py_repr/1) <> ")"
    end
  end

  def py_repr_map(m) do
    "{" <>
      Enum.map_join(m, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end) <> "}"
  end

  def py_repr(x) when is_binary(x), do: "'" <> x <> "'"
  def py_repr(x), do: py_str(x)

  # === String methods ===
  def py_str_find(s, sub) do
    case String.split(s, sub, parts: 2) do
      [_] -> -1
      [before, _] -> String.length(before)
    end
  end

  def py_str_count(s, ""), do: String.length(s) + 1
  def py_str_count(s, sub), do: length(String.split(s, sub)) - 1

  def py_str_index(s, sub) do
    case py_str_find(s, sub) do
      -1 -> raise RuntimeError, "substring not found"
      idx -> idx
    end
  end

  def py_list_index(list, x) do
    case Enum.find_index(list, fn v -> v == x end) do
      nil -> raise RuntimeError, "#{inspect(x)} is not in list"
      idx -> idx
    end
  end

  # === Numeric formatting ===
  def py_hex(n) when n < 0, do: "-0x" <> String.downcase(Integer.to_string(-n, 16))
  def py_hex(n), do: "0x" <> String.downcase(Integer.to_string(n, 16))

  def py_oct(n) when n < 0, do: "-0o" <> Integer.to_string(-n, 8)
  def py_oct(n), do: "0o" <> Integer.to_string(n, 8)

  def py_bin(n) when n < 0, do: "-0b" <> Integer.to_string(-n, 2)
  def py_bin(n), do: "0b" <> Integer.to_string(n, 2)

  def py_abs(x) when is_boolean(x), do: py_bool_to_int(x)
  def py_abs(x), do: abs(x)

  # === Banker's rounding (Python semantics) ===
  def py_round(x) when is_integer(x), do: x

  def py_round(x) when is_float(x) do
    truncated = trunc(x)
    diff = x - truncated

    cond do
      abs(diff) < 0.5 -> truncated
      abs(diff) > 0.5 -> if x > 0, do: truncated + 1, else: truncated - 1
      rem(truncated, 2) == 0 -> truncated
      true -> if x > 0, do: truncated + 1, else: truncated - 1
    end
  end

  def py_round(x, _n) when is_integer(x), do: x

  def py_round(x, n) when is_float(x) do
    multiplier = :math.pow(10, n)
    py_round(x * multiplier) / multiplier
  end

  # === heapq (min-heap on sorted list) ===

  # Pylixir backs Python's `heapq` with a *sorted list* — O(n) push/pop
  # vs `heapq`'s O(log n). Adequate for competitive-programming inputs;
  # a true binary heap would need a tree-backed structure. Heap items
  # compare via Erlang's term order — works for tuples like
  # `{dist, vertex}` (Dijkstra / A* / etc.) which is the dominant
  # heapq use case.

  def py_heappush(heap, item) when is_list(heap),
    do: Enum.sort([item | heap])

  def py_heappop([head | tail]), do: {head, tail}
  def py_heappop([]), do: raise(RuntimeError, "heappop from empty heap")

  def py_heapify(list) when is_list(list), do: Enum.sort(list)

  # === Bitwise / set polymorphism ===

  # Python's `&` / `|` / `^` are overloaded: bitwise on ints, set ops
  # on sets. Pylixir can't tell at codegen time which the operands are,
  # so dispatch at runtime. `MapSet` covers the set case; everything
  # else routes to `Bitwise.band/2` etc. (Erlang's BIFs raise loudly
  # on truly unsupported types — matching Python's TypeError shape.)
  def py_band(%MapSet{} = a, %MapSet{} = b), do: MapSet.intersection(a, b)
  def py_band(a, b), do: Bitwise.band(a, b)

  def py_bor(%MapSet{} = a, %MapSet{} = b), do: MapSet.union(a, b)
  def py_bor(a, b), do: Bitwise.bor(a, b)

  def py_bxor(%MapSet{} = a, %MapSet{} = b),
    do: MapSet.union(MapSet.difference(a, b), MapSet.difference(b, a))

  def py_bxor(a, b), do: Bitwise.bxor(a, b)

  # === itertools.combinations ===

  # Mirrors Python's `itertools.combinations(iter, r)` — every r-length
  # subset of `iter` in lexicographic order. Returns lists rather than
  # tuples (Python returns tuples, but every common downstream use —
  # `set(combo)`, `for x in combo`, `combo[i]` — works equivalently
  # on lists in Pylixir's lowering).
  def py_combinations(enum, r) when is_integer(r) and r >= 0 do
    list = if is_list(enum), do: enum, else: Enum.to_list(enum)
    py_combinations_inner(list, r)
  end

  # Recursive inner — public `def` (not `defp`) to keep the
  # all-defs-no-defps invariant the helpers-codegen sentinel relies
  # on. Unused `def`s don't warn; unused `defp`s would.
  def py_combinations_inner(_, 0), do: [[]]
  def py_combinations_inner([], _), do: []

  def py_combinations_inner([h | t], r) do
    with_h = Enum.map(py_combinations_inner(t, r - 1), &[h | &1])
    without_h = py_combinations_inner(t, r)
    with_h ++ without_h
  end

  # === Bisect (sorted-list insertion-point search) ===

  # Mirrors Python's `bisect.bisect_left(a, x)` — index where `x` should
  # be inserted to keep `a` sorted; for equal values, returns the
  # leftmost position. O(n) in this implementation (vs O(log n) in
  # Python's), but iterative Erlang BIFs make the constant low.
  def py_bisect_left(list, x) when is_list(list) do
    Enum.find_index(list, fn v -> v >= x end) || length(list)
  end

  # Mirrors `bisect.bisect_right(a, x)` — rightmost insertion position
  # for equal values.
  def py_bisect_right(list, x) when is_list(list) do
    Enum.find_index(list, fn v -> v > x end) || length(list)
  end

  # === Integer methods ===

  # Python's `int.bit_length()` — bits required to represent the int
  # in binary (excluding sign and leading zeros). `0` returns `0`;
  # negative numbers behave as their absolute value.
  def py_int_bit_length(0), do: 0
  def py_int_bit_length(n) when n < 0, do: py_int_bit_length(-n)
  def py_int_bit_length(n) when is_integer(n), do: length(Integer.digits(n, 2))

  # === Input ===
  def py_input(prompt) do
    case IO.gets(prompt) do
      :eof -> raise RuntimeError, "EOFError"
      line -> String.trim_trailing(line, "\n")
    end
  end

  # Drains stdin and returns its entire contents as a binary, like
  # Python's `sys.stdin.read()`. Reads until EOF; an immediate EOF
  # yields the empty string (Python returns "" rather than raising).
  def py_stdin_read do
    Stream.repeatedly(fn -> IO.read(:stdio, :line) end)
    |> Stream.take_while(&(&1 != :eof))
    |> Enum.join("")
  end

  # Reads one line from stdin, *including* the trailing newline if
  # present — matching Python's `sys.stdin.readline()`. At EOF Python
  # returns "" (not :eof / not a raise), so we surface the same.
  def py_stdin_readline do
    case IO.read(:stdio, :line) do
      :eof -> ""
      {:error, reason} -> raise RuntimeError, "stdin readline failed: #{inspect(reason)}"
      line -> line
    end
  end

  # --- HELPERS END ---
end
