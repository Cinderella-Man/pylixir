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

  def py_add(a, b) when is_boolean(a), do: py_add(py_bool_to_int(a), b)
  def py_add(a, b) when is_boolean(b), do: py_add(a, py_bool_to_int(b))
  def py_add(a, b) when is_binary(a) and is_binary(b), do: a <> b
  def py_add(a, b) when is_number(a) and is_number(b), do: a + b
  def py_add(a, b) when is_list(a) and is_list(b), do: a ++ b
  def py_add(a, b), do: a + b

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

  def py_getitem(c, k) when is_list(c), do: Enum.at(c, k)
  def py_getitem(c, k) when is_binary(c), do: String.at(c, k)
  def py_getitem(c, k) when is_tuple(c) and k >= 0, do: elem(c, k)
  def py_getitem(c, k) when is_tuple(c), do: elem(c, tuple_size(c) + k)
  def py_getitem(c, k) when is_map(c), do: Map.fetch!(c, k)

  def py_setitem(c, k, v) when is_list(c), do: List.replace_at(c, k, v)
  def py_setitem(c, k, v) when is_map(c), do: Map.put(c, k, v)

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

  # === Input ===
  def py_input(prompt) do
    case IO.gets(prompt) do
      :eof -> raise RuntimeError, "EOFError"
      line -> String.trim_trailing(line, "\n")
    end
  end

  # --- HELPERS END ---
end
