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

  # Python's `(1, 2) + (3, 4) == (1, 2, 3, 4)` — tuple concat. Round-
  # trip through lists for the concat (no native tuple-append in BEAM)
  # and convert back. Matches the existing list/binary concat clauses.
  def py_add(a, b) when is_tuple(a) and is_tuple(b),
    do: (Tuple.to_list(a) ++ Tuple.to_list(b)) |> List.to_tuple()

  def py_add(a, b), do: a + b

  # RFC §6.11 — booleans coerce to ints in arithmetic.
  def py_sub(a, b) when is_boolean(a), do: py_sub(py_bool_to_int(a), b)
  def py_sub(a, b) when is_boolean(b), do: py_sub(a, py_bool_to_int(b))
  # Python: `set - set` is set difference. Pylixir's set rep is MapSet.
  def py_sub(%MapSet{} = a, %MapSet{} = b), do: MapSet.difference(a, b)
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

  # Python tuple * int — repeat the tuple's elements. `(1, 2) * 3
  # == (1, 2, 1, 2, 1, 2)`. Round-trip through list because that's
  # the only way to concat in BEAM; the int * tuple form mirrors.
  def py_mult(a, b) when is_tuple(a) and is_integer(b) and b > 0,
    do: a |> Tuple.to_list() |> List.duplicate(b) |> Enum.concat() |> List.to_tuple()

  def py_mult(a, b) when is_tuple(a) and is_integer(b), do: {}

  def py_mult(a, b) when is_integer(a) and is_tuple(b) and a > 0,
    do: b |> Tuple.to_list() |> List.duplicate(a) |> Enum.concat() |> List.to_tuple()

  def py_mult(a, b) when is_integer(a) and is_tuple(b), do: {}

  def py_mult(a, b), do: a * b

  def py_pow(base, exp) when is_integer(base) and is_integer(exp) and exp >= 0,
    do: Integer.pow(base, exp)

  def py_pow(base, exp), do: :math.pow(base, exp)

  # Python's `set.pop()` / `(expr).pop()` — pop an arbitrary element
  # from a set, or the last from a list. Used when the receiver is an
  # expression (not a bare Name) and there's nothing to rebind, e.g.
  # `(s1 - s2).pop()`. Returns just the popped value (the remaining
  # collection is discarded). Python's set pop is documented as
  # arbitrary order; we pick the first via MapSet.to_list.
  def py_pop_any(%MapSet{} = s), do: MapSet.to_list(s) |> hd()
  def py_pop_any(list) when is_list(list), do: List.last(list)

  # `d.pop(key)` / `coll.pop(idx)` in expression context — value-only
  # (no rebind, since the receiver isn't a bare Name target). For
  # dict: Map.get; for list: Enum.at. The mutation is lost; use the
  # `x = d.pop(k)` Assign form to keep it.
  def py_pop_value(map, key) when is_map(map) and not is_struct(map), do: Map.get(map, key)
  def py_pop_value(list, idx) when is_list(list), do: Enum.at(list, idx)

  def py_pop_value_default(map, key, default) when is_map(map) and not is_struct(map),
    do: Map.get(map, key, default)

  def py_pop_value_default(list, idx, _default) when is_list(list), do: Enum.at(list, idx)

  # `dict.fromkeys(iter[, default])` — build a dict mapping each key in
  # `keys` to the same `default` (Python defaults to None / `nil`).
  # The 1-arg shape passes `nil` from the dispatch site; this 2-arity
  # def covers both. We accept strings/tuples via py_iter_to_list so
  # the helper works on the same iterables Python's fromkeys accepts.
  def py_dict_fromkeys(keys, default) when is_list(keys),
    do: Map.new(keys, fn k -> {k, default} end)

  def py_dict_fromkeys(keys, default), do: py_dict_fromkeys(py_iter_to_list(keys), default)

  # `dict.popitem()` in expression context — returns an arbitrary
  # `{k, v}` tuple. Python 3.7+ guarantees LIFO, but Elixir's Map has
  # no insertion-order guarantee, so we return whatever `Map.to_list/1`
  # yields first. Fine for tests that don't depend on which item.
  def py_dict_popitem(map) when is_map(map) and not is_struct(map),
    do: map |> Map.to_list() |> hd()

  # Python's `list.pop()` / `dict.pop(key[, default])` capture-return form.
  # Returned tuple is `{popped_value, new_collection}` — caller destructures.
  # Polymorphic on list (index-based) vs map (key-based); branches at runtime
  # because the static converter doesn't know the container type.
  def py_pop_last(list) when is_list(list), do: List.pop_at(list, -1)

  def py_pop_at(list, idx) when is_list(list), do: List.pop_at(list, idx)

  def py_pop_at(map, key) when is_map(map) and not is_struct(map),
    do: Map.pop(map, key)

  def py_pop_at_default(map, key, default) when is_map(map) and not is_struct(map),
    do: Map.pop(map, key, default)

  def py_pop_at_default(list, idx, _default) when is_list(list),
    do: List.pop_at(list, idx)

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
  # Python's `'fmt' % args` — string %-formatting. `args` is a tuple
  # of values to substitute or a single value for the 1-arg shape.
  # Common conversion specifiers: %d %s %f %x %X %o %c %%. Supports
  # `-` left-align, `0` zero-pad, `+` always-sign, width, precision.
  def py_mod(a, args) when is_binary(a) do
    arg_list =
      cond do
        is_tuple(args) -> Tuple.to_list(args)
        true -> [args]
      end

    py_str_percent_format(a, arg_list, [])
  end

  def py_mod(a, b) when is_integer(a) and is_integer(b), do: Integer.mod(a, b)
  def py_mod(a, b) when is_number(a) and is_number(b), do: a - b * :math.floor(a / b)

  # Walk the template, consuming `%spec` placeholders and appending
  # them to `out`. `args` is consumed left-to-right as we hit
  # placeholders. Recursive on the remainder string.
  def py_str_percent_format("", _args, out), do: out |> Enum.reverse() |> IO.iodata_to_binary()

  def py_str_percent_format("%%" <> rest, args, out),
    do: py_str_percent_format(rest, args, ["%" | out])

  def py_str_percent_format("%" <> rest, args, out) do
    {spec, rest} = parse_percent_spec(rest, "")
    [arg | tail_args] = args
    formatted = format_percent_value(spec, arg)
    py_str_percent_format(rest, tail_args, [formatted | out])
  end

  def py_str_percent_format(<<ch::utf8, rest::binary>>, args, out),
    do: py_str_percent_format(rest, args, [<<ch::utf8>> | out])

  # Parse a `%`-spec into `{spec_string, remainder}`. Spec syntax is
  # `[flags][width][.precision]type` — accumulate until we hit a
  # type char (a-zA-Z) which terminates the spec.
  def parse_percent_spec(<<ch::utf8, rest::binary>>, acc) do
    if (ch >= ?a and ch <= ?z) or (ch >= ?A and ch <= ?Z) do
      {acc <> <<ch::utf8>>, rest}
    else
      parse_percent_spec(rest, acc <> <<ch::utf8>>)
    end
  end

  def parse_percent_spec("", acc), do: {acc, ""}

  # Format a single value per Python's %-spec semantics. `spec` is
  # the post-`%` characters (e.g. `"05d"`, `".2f"`, `"x"`). Returns
  # the formatted string.
  def format_percent_value(spec, value) do
    {flags, rest} =
      parse_percent_flags(spec, %{left: false, zero: false, plus: false, space: false})

    {width, rest} = parse_percent_int(rest, 0)
    {precision, rest} = parse_percent_precision(rest)
    type = rest

    formatted = format_percent_typed(type, value, precision)
    formatted = apply_percent_sign(formatted, value, flags, type)
    apply_percent_pad(formatted, width, flags)
  end

  def parse_percent_flags(<<?-, rest::binary>>, flags),
    do: parse_percent_flags(rest, %{flags | left: true})

  def parse_percent_flags(<<?0, rest::binary>>, flags),
    do: parse_percent_flags(rest, %{flags | zero: true})

  def parse_percent_flags(<<?+, rest::binary>>, flags),
    do: parse_percent_flags(rest, %{flags | plus: true})

  def parse_percent_flags(<<?\s, rest::binary>>, flags),
    do: parse_percent_flags(rest, %{flags | space: true})

  def parse_percent_flags(rest, flags), do: {flags, rest}

  def parse_percent_int(<<ch, rest::binary>>, acc) when ch >= ?0 and ch <= ?9,
    do: parse_percent_int(rest, acc * 10 + (ch - ?0))

  def parse_percent_int(rest, acc), do: {acc, rest}

  def parse_percent_precision(<<?., rest::binary>>) do
    {p, rest} = parse_percent_int(rest, 0)
    {p, rest}
  end

  def parse_percent_precision(rest), do: {nil, rest}

  # Per-type conversion. Precision applies to %f (decimal digits) and
  # %s (max string length). Width/flags are applied later.
  def format_percent_typed("d", v, _p) when is_integer(v), do: Integer.to_string(abs(v))
  def format_percent_typed("d", v, _p) when is_float(v), do: Integer.to_string(abs(trunc(v)))
  def format_percent_typed("i", v, p), do: format_percent_typed("d", v, p)
  def format_percent_typed("s", v, nil), do: py_str(v)

  def format_percent_typed("s", v, p) when is_integer(p),
    do: v |> py_str() |> String.slice(0, p)

  def format_percent_typed("f", v, nil) do
    v_f = if is_integer(v), do: v * 1.0, else: v
    :erlang.float_to_binary(v_f, decimals: 6)
  end

  def format_percent_typed("f", v, p) when is_integer(p) do
    v_f = if is_integer(v), do: v * 1.0, else: v
    :erlang.float_to_binary(v_f, decimals: p)
  end

  def format_percent_typed("e", v, p) do
    v_f = if is_integer(v), do: v * 1.0, else: v
    digits = if is_integer(p), do: p, else: 6
    :erlang.float_to_binary(v_f, scientific: digits)
  end

  def format_percent_typed("x", v, _p) when is_integer(v),
    do: v |> abs() |> Integer.to_string(16) |> String.downcase()

  def format_percent_typed("X", v, _p) when is_integer(v),
    do: v |> abs() |> Integer.to_string(16)

  def format_percent_typed("o", v, _p) when is_integer(v),
    do: v |> abs() |> Integer.to_string(8)

  def format_percent_typed("b", v, _p) when is_integer(v),
    do: v |> abs() |> Integer.to_string(2)

  def format_percent_typed("c", v, _p) when is_integer(v),
    do: <<v::utf8>>

  def format_percent_typed("c", v, _p) when is_binary(v), do: v
  def format_percent_typed("r", v, _p), do: py_repr(v)

  # Unknown specifier — fall back to py_str so we don't crash on a
  # spec we haven't enumerated yet. (Python would raise; we choose
  # graceful degradation over a hard error in transpiled code.)
  def format_percent_typed(_, v, _p), do: py_str(v)

  # Re-attach the sign for numeric conversions. Negative values
  # already lost their sign in `format_percent_typed` (we used
  # `abs/1`), so we re-add it here based on the original value.
  def apply_percent_sign(s, v, flags, type)
      when type in ["d", "i", "f", "e"] and is_number(v) do
    cond do
      v < 0 -> "-" <> s
      flags.plus -> "+" <> s
      flags.space -> " " <> s
      true -> s
    end
  end

  def apply_percent_sign(s, _v, _flags, _type), do: s

  # Width padding: left-align with spaces (`-`), zero-pad numerics
  # (`0`), otherwise space-pad on the left.
  def apply_percent_pad(s, width, flags) when width > 0 do
    diff = width - String.length(s)

    cond do
      diff <= 0 -> s
      flags.left -> s <> String.duplicate(" ", diff)
      flags.zero -> apply_zero_pad(s, diff)
      true -> String.duplicate(" ", diff) <> s
    end
  end

  def apply_percent_pad(s, _width, _flags), do: s

  # Zero-pad keeps the sign on the LEFT (`"-005"` not `"-005"` → `"-005"`,
  # vs. the naive `"00-5"` we'd get from blind prepend).
  def apply_zero_pad("-" <> rest, diff), do: "-" <> String.duplicate("0", diff) <> rest
  def apply_zero_pad("+" <> rest, diff), do: "+" <> String.duplicate("0", diff) <> rest
  def apply_zero_pad(s, diff), do: String.duplicate("0", diff) <> s

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

  # Iterator handle (positive int returned by `py_iter_make/1`). Check
  # process dict to disambiguate from a regular int (where `x in 5`
  # would raise TypeError in Python anyway; we return false here for
  # the rare misuse).
  def py_in(x, c) when is_integer(c) do
    case Process.get({:pylixir_iter, c}) do
      nil -> false
      _ -> py_iter_in(x, c)
    end
  end

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

  # S2 — tiny helper for `print(<bool>)` to drop the inline if/else
  # expansion at every call site. Only `true`/`false` clauses — no
  # catch-all on purpose: emit sites are gated on `TypeInfer` saying
  # `{:bool}`, so a non-bool reaching here means inference was wrong.
  # FunctionClauseError surfaces the bug loudly. Keeping the helper
  # zero-dependency lets it tree-shake without pulling `py_str`.
  def py_bool_str(true), do: "True"
  def py_bool_str(false), do: "False"

  def py_str(true), do: "True"
  def py_str(false), do: "False"
  def py_str(nil), do: "None"
  def py_str(x) when is_atom(x), do: Atom.to_string(x)
  def py_str(x) when is_list(x), do: py_repr(x)
  def py_str(x) when is_tuple(x), do: py_repr(x)
  def py_str(%MapSet{} = s), do: py_repr(s)
  def py_str(x) when is_map(x) and not is_struct(x), do: py_repr(x)
  def py_str(x) when is_float(x), do: py_str_float(x)
  def py_str(x), do: to_string(x)

  # Python's `str(float)` / `repr(float)`. Python uses fixed-point for
  # `1e-4 <= abs(x) < 1e16` and scientific (`e[+-]NN`, exponent zero-
  # padded to >=2 digits) elsewhere. BEAM's `:erlang.float_to_binary(x,
  # [:short])` gives the canonical short repr — sometimes scientific
  # for whole-number floats like `1000.0` (`"1.0e3"`), which doesn't
  # match Python. We use the short repr as the source of digits and
  # decide format based on the exponent.
  # BEAM has no IEEE +inf / -inf float representation; `float("inf")`
  # at the codegen level clamps to `+/- 1.0e308` (the max-finite IEEE
  # double). Print those exact clamp values back out as `inf`/`-inf`
  # to match Python's repr. False-positive risk (a real `1.0e308`
  # computation result) is theoretical — algorithmic Python code
  # doesn't land on that exact value.
  def py_str_float(1.0e308), do: "inf"
  def py_str_float(-1.0e308), do: "-inf"

  def py_str_float(x) when is_float(x) do
    s = :erlang.float_to_binary(x, [:short])

    case String.split(s, "e") do
      [_only] ->
        s

      [mantissa, exp_str] ->
        exp = String.to_integer(exp_str)

        cond do
          exp >= 16 or exp < -4 -> python_sci(mantissa, exp)
          true -> shift_decimal(mantissa, exp)
        end
    end
  end

  # Format as Python's scientific: `e[+-]NN`, exponent always signed
  # and zero-padded to >=2 digits. Mantissa already has a `.`; Python
  # drops trailing zeros after the decimal but keeps at least `.0`-
  # equivalent — actually Python's repr drops the `.0` entirely in
  # sci form: `1e+20` not `1.0e+20`. Mirror that.
  def python_sci(mantissa, exp) do
    sign = if exp >= 0, do: "+", else: "-"
    abs_exp = abs(exp)
    exp_padded = abs_exp |> Integer.to_string() |> String.pad_leading(2, "0")
    mantissa_clean = drop_trailing_zero_decimal(mantissa)
    mantissa_clean <> "e" <> sign <> exp_padded
  end

  # `"1.0"` → `"1"`; `"1.5"` → `"1.5"`. Used in Python sci-notation
  # mantissa formatting where the `.0` is dropped.
  def drop_trailing_zero_decimal(s) do
    case String.split(s, ".") do
      [int_part, "0"] -> int_part
      _ -> s
    end
  end

  # Given a mantissa like `"-1.5"` and an exponent like `10`, produce
  # the fixed-point form: `"-15000000000.0"`. Handles negative
  # exponents (`shift_decimal("1.5", -3)` → `"0.0015"`).
  def shift_decimal(mantissa, exp) do
    {sign, rest} =
      case mantissa do
        "-" <> rest -> {"-", rest}
        other -> {"", other}
      end

    {int_part, frac_part} =
      case String.split(rest, ".") do
        [i] -> {i, ""}
        [i, f] -> {i, f}
      end

    digits = int_part <> frac_part
    decimal_pos = String.length(int_part) + exp

    formatted =
      cond do
        decimal_pos >= String.length(digits) ->
          # Right-pad with zeros and append `.0`.
          padded = digits <> String.duplicate("0", decimal_pos - String.length(digits))
          padded <> ".0"

        decimal_pos <= 0 ->
          # Left-pad with zeros after `0.`.
          leading_zeros = String.duplicate("0", -decimal_pos)
          "0." <> leading_zeros <> digits

        true ->
          {l, r} = String.split_at(digits, decimal_pos)
          r = if r == "", do: "0", else: r
          l <> "." <> r
      end

    sign <> formatted
  end

  # Python-correct `repr` of a string. Implements quote-choice (prefer
  # single; switch to double when the input contains `'` and no `"`)
  # plus the full escape table: `\\` `\n` `\t` `\r` named, every
  # other C0 (0x00-0x1F) and C1 (0x7F-0x9F) control codepoint as
  # `\xNN`. The algorithm is duplicated in
  # `Pylixir.LiteralFold.str_repr/1` for the compile-time fold path;
  # a sync test in `test/pylixir/repr_sync_test.exs` asserts the two
  # paths produce identical output for a fuzz corpus, catching any
  # drift.
  #
  # No private helpers — `helpers_codegen.ex` only parses top-level
  # `def`s within the sentinel block, so we inline the escape walk
  # rather than refactor into smaller defs.
  def py_repr(x) when is_binary(x) do
    escaped =
      x
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")
      |> String.replace("\r", "\\r")

    escaped =
      for <<cp::utf8 <- escaped>>, into: "" do
        cond do
          cp <= 0x08 or cp == 0x0B or cp == 0x0C or (cp >= 0x0E and cp <= 0x1F) ->
            "\\x" <>
              (cp |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0"))

          cp >= 0x7F and cp <= 0x9F ->
            "\\x" <>
              (cp |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0"))

          true ->
            <<cp::utf8>>
        end
      end

    has_single = String.contains?(escaped, "'")
    has_double = String.contains?(escaped, "\"")

    if has_single and not has_double do
      "\"" <> escaped <> "\""
    else
      "'" <> String.replace(escaped, "'", "\\'") <> "'"
    end
  end

  def py_repr(x) when is_list(x),
    do: "[" <> Enum.map_join(x, ", ", &py_repr/1) <> "]"

  def py_repr(x) when is_tuple(x) do
    items = Tuple.to_list(x)

    case items do
      [single] -> "(" <> py_repr(single) <> ",)"
      _ -> "(" <> Enum.map_join(items, ", ", &py_repr/1) <> ")"
    end
  end

  def py_repr(%MapSet{} = s) do
    case MapSet.to_list(s) do
      [] -> "set()"
      items -> "{" <> Enum.map_join(items, ", ", &py_repr/1) <> "}"
    end
  end

  def py_repr(x) when is_map(x) and not is_struct(x) do
    "{" <>
      Enum.map_join(x, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end) <> "}"
  end

  def py_repr(x), do: py_str(x)

  # S3 — Python-correct quote choice for `repr(<str>)`, used by the
  # typed-container print path. Kept as a standalone helper (rather
  # than delegating through `py_repr` or an outer module) so tree-
  # shaking can drop it when the inline path is the only consumer —
  # pulling `py_repr` in would also pull `py_str` via its catch-all.
  # Algorithm identical to `py_repr/1`'s binary clause; the sync
  # test in `repr_sync_test.exs` keeps them aligned.
  def py_repr_str(s) when is_binary(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")
      |> String.replace("\r", "\\r")

    escaped =
      for <<cp::utf8 <- escaped>>, into: "" do
        cond do
          cp <= 0x08 or cp == 0x0B or cp == 0x0C or (cp >= 0x0E and cp <= 0x1F) ->
            "\\x" <>
              (cp |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0"))

          cp >= 0x7F and cp <= 0x9F ->
            "\\x" <>
              (cp |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0"))

          true ->
            <<cp::utf8>>
        end
      end

    has_single = String.contains?(escaped, "'")
    has_double = String.contains?(escaped, "\"")

    if has_single and not has_double do
      "\"" <> escaped <> "\""
    else
      "'" <> String.replace(escaped, "'", "\\'") <> "'"
    end
  end

  # === String methods ===
  def py_str_find(s, sub) do
    case String.split(s, sub, parts: 2) do
      [_] -> -1
      [before, _] -> String.length(before)
    end
  end

  # `s.find(sub, start)` / `s.find(sub, start, stop)` — search inside
  # the slice s[start:stop]. Returned index is absolute (start-relative
  # is wrong for Python). -1 if not found.
  def py_str_find(s, sub, start) do
    case py_str_find(String.slice(s, start..-1//1), sub) do
      -1 -> -1
      idx -> idx + start
    end
  end

  def py_str_find(s, sub, start, stop) do
    case py_str_find(String.slice(s, start, stop - start), sub) do
      -1 -> -1
      idx -> idx + start
    end
  end

  # `s.rfind(sub[, start[, stop]])` — same as find but right-anchored.
  # Reverse the string + sub, find in reversed, then map back.
  def py_str_rfind(s, sub) do
    case String.split(s, sub) do
      [_] ->
        -1

      parts ->
        # Length of everything except the last segment, plus (n-1) sub-lengths,
        # gives the start of the last sub-occurrence.
        {init, [_last]} = Enum.split(parts, -1)

        Enum.reduce(init, 0, fn p, acc -> acc + String.length(p) + String.length(sub) end) -
          String.length(sub)
    end
  end

  def py_str_rfind(s, sub, start), do: py_str_rfind(s, sub, start, String.length(s))

  def py_str_rfind(s, sub, start, stop) do
    sliced = String.slice(s, start, stop - start)

    case py_str_rfind(sliced, sub) do
      -1 -> -1
      idx -> idx + start
    end
  end

  # Python's `s.expandtabs(tabsize)` — replace each `\t` with enough
  # spaces to reach the next tab-stop column. Column tracking resets
  # at each newline. Default tabsize matches Python's (8).
  def py_str_expandtabs(s, tabsize) when is_binary(s) and is_integer(tabsize) and tabsize > 0,
    do: py_str_expandtabs_loop(String.graphemes(s), tabsize, 0, [])

  def py_str_expandtabs(s, _tabsize) when is_binary(s), do: s

  def py_str_expandtabs_loop([], _tabsize, _col, out),
    do: out |> Enum.reverse() |> IO.iodata_to_binary()

  def py_str_expandtabs_loop(["\t" | rest], tabsize, col, out) do
    spaces = tabsize - rem(col, tabsize)
    py_str_expandtabs_loop(rest, tabsize, col + spaces, [String.duplicate(" ", spaces) | out])
  end

  def py_str_expandtabs_loop(["\n" | rest], tabsize, _col, out),
    do: py_str_expandtabs_loop(rest, tabsize, 0, ["\n" | out])

  def py_str_expandtabs_loop([g | rest], tabsize, col, out),
    do: py_str_expandtabs_loop(rest, tabsize, col + 1, [g | out])

  # Python's `str.maketrans(from, to)` — returns a dict mapping each
  # grapheme of `from` to the corresponding grapheme of `to`. Both
  # must be the same length; Python raises ValueError otherwise.
  # The returned dict is used by `py_str_translate/2`.
  def py_str_maketrans(from_s, to_s) when is_binary(from_s) and is_binary(to_s) do
    from_chars = String.graphemes(from_s)
    to_chars = String.graphemes(to_s)

    if length(from_chars) != length(to_chars) do
      raise ArgumentError, "the first two maketrans arguments must have equal length"
    end

    Enum.zip(from_chars, to_chars) |> Map.new()
  end

  # Python's `s.translate(table)` — replace each grapheme via the
  # table. Missing keys leave the grapheme unchanged. Table may map
  # either graphemes (from our `py_str_maketrans`) or codepoint-ints
  # (Python's `dict.fromkeys(map(ord, "abc"), None)` idiom) — we
  # accept both shapes.
  def py_str_translate(s, table) when is_binary(s) and is_map(table) do
    s
    |> String.graphemes()
    |> Enum.map_join("", fn g ->
      cond do
        Map.has_key?(table, g) ->
          Map.fetch!(table, g) || ""

        true ->
          # Codepoint-int lookup for Python-style ord-keyed tables.
          [cp | _] = String.to_charlist(g)

          case Map.fetch(table, cp) do
            {:ok, nil} -> ""
            {:ok, v} when is_integer(v) -> <<v::utf8>>
            {:ok, v} when is_binary(v) -> v
            :error -> g
          end
      end
    end)
  end

  # Python's `s.replace(old, new, count)` with bounded count. Walks
  # left-to-right replacing the first `count` occurrences. count<=0
  # returns the string unchanged (Python's behavior). Negative count
  # (-1) means "replace all" — defer to global String.replace.
  def py_str_replace_n(s, old, new, count)
      when is_binary(s) and is_binary(old) and is_binary(new) and is_integer(count) do
    cond do
      count == 0 -> s
      count < 0 -> String.replace(s, old, new)
      old == "" -> s
      true -> py_str_replace_n_loop(s, old, new, count, "")
    end
  end

  def py_str_replace_n_loop(s, _old, _new, 0, acc), do: acc <> s

  def py_str_replace_n_loop(s, old, new, count, acc) do
    case :binary.split(s, old) do
      [whole] ->
        acc <> whole

      [before, after_part] ->
        py_str_replace_n_loop(after_part, old, new, count - 1, acc <> before <> new)
    end
  end

  # Python's `str.rsplit(sep, maxsplit)` — right-anchored, bounded.
  # Elixir's `String.split(s, sep, parts: N)` is LEFT-anchored, so for
  # `"a,b,c,d".rsplit(",", 1)` Python gives `["a,b,c", "d"]` while a
  # naive left-split with parts:2 gives `["a", "b,c,d"]`. Reversing
  # the string + sep, splitting from the left with the same maxsplit,
  # then reversing the pieces back and the list yields the right
  # semantics. `maxsplit == -1` means "split everywhere" (Python's
  # convention) — degenerate to a plain split.
  def py_str_rsplit(s, sep, -1), do: String.split(s, sep)

  def py_str_rsplit(s, sep, maxsplit)
      when is_binary(s) and is_binary(sep) and is_integer(maxsplit) do
    String.reverse(s)
    |> String.split(String.reverse(sep), parts: maxsplit + 1)
    |> Enum.map(&String.reverse/1)
    |> Enum.reverse()
  end

  def py_str_count(s, ""), do: String.length(s) + 1
  def py_str_count(s, sub), do: length(String.split(s, sub)) - 1

  # Python's `str.islower()` / `str.isupper()` — non-empty AND every
  # cased char matches the predicate AND at least one cased char
  # exists. A regex like `^[a-z ]+$` would falsely say "abc 123" is
  # lower-case; Python requires the presence of *at least one* cased
  # character, which is what the != against the case-flipped form
  # checks.
  def py_str_islower(""), do: false

  def py_str_islower(s) when is_binary(s) do
    has_cased? = s != String.upcase(s) or s != String.downcase(s)
    has_cased? and s == String.downcase(s)
  end

  def py_str_isupper(""), do: false

  def py_str_isupper(s) when is_binary(s) do
    has_cased? = s != String.upcase(s) or s != String.downcase(s)
    has_cased? and s == String.upcase(s)
  end

  # Python's `str.title()` — capitalise the first letter of every run
  # of alphabetic characters; lowercase the rest. Non-alpha chars
  # reset the "first letter" state.
  def py_str_title(s) when is_binary(s) do
    s
    |> String.graphemes()
    |> Enum.map_reduce(true, fn ch, at_word_start? ->
      alpha? = Regex.match?(~r/^[[:alpha:]]$/u, ch)

      cond do
        not alpha? -> {ch, true}
        at_word_start? -> {String.upcase(ch), false}
        true -> {String.downcase(ch), false}
      end
    end)
    |> elem(0)
    |> Enum.join()
  end

  # Python's `str.capitalize()` — first char to upper, everything else
  # to lower. Empty string is unchanged.
  def py_str_capitalize(""), do: ""

  def py_str_capitalize(s) when is_binary(s) do
    {first, rest} = String.split_at(s, 1)
    String.upcase(first) <> String.downcase(rest)
  end

  # Python's `str.swapcase()` — flip case of every char.
  def py_str_swapcase(s) when is_binary(s) do
    s
    |> String.graphemes()
    |> Enum.map(fn ch ->
      cond do
        ch == String.upcase(ch) and ch != String.downcase(ch) -> String.downcase(ch)
        ch == String.downcase(ch) and ch != String.upcase(ch) -> String.upcase(ch)
        true -> ch
      end
    end)
    |> Enum.join()
  end

  # Python's `s.strip(chars)` / `s.lstrip(chars)` / `s.rstrip(chars)`
  # treat `chars` as a SET of chars to strip from the relevant end
  # repeatedly — NOT a substring (which is what Elixir's String.trim/2
  # would do). Iterates grapheme by grapheme until a non-set char is
  # found.
  # Python's `s.startswith(prefix_or_tuple)` and `s.endswith(...)` —
  # the prefix can be a single string OR a tuple of strings. Elixir's
  # `String.starts_with?/2` accepts a string or a LIST; coerce a
  # tuple to a list. Single-string case passes through unchanged.
  def py_str_startswith(s, prefix) when is_tuple(prefix),
    do: String.starts_with?(s, Tuple.to_list(prefix))

  def py_str_startswith(s, prefix), do: String.starts_with?(s, prefix)

  def py_str_endswith(s, suffix) when is_tuple(suffix),
    do: String.ends_with?(s, Tuple.to_list(suffix))

  def py_str_endswith(s, suffix), do: String.ends_with?(s, suffix)

  def py_str_lstrip_chars(s, chars) when is_binary(s) and is_binary(chars) do
    set = chars |> String.graphemes() |> MapSet.new()
    py_str_strip_iter(s, set, :leading)
  end

  def py_str_rstrip_chars(s, chars) when is_binary(s) and is_binary(chars) do
    set = chars |> String.graphemes() |> MapSet.new()
    py_str_strip_iter(s, set, :trailing)
  end

  def py_str_strip_chars(s, chars) when is_binary(s) and is_binary(chars) do
    set = chars |> String.graphemes() |> MapSet.new()
    s |> py_str_strip_iter(set, :leading) |> py_str_strip_iter(set, :trailing)
  end

  def py_str_strip_iter(s, set, :leading) do
    case String.next_grapheme(s) do
      nil ->
        s

      {ch, rest} ->
        if MapSet.member?(set, ch), do: py_str_strip_iter(rest, set, :leading), else: s
    end
  end

  def py_str_strip_iter(s, set, :trailing) do
    case String.last(s) do
      nil ->
        s

      ch ->
        if MapSet.member?(set, ch),
          do: py_str_strip_iter(String.slice(s, 0, String.length(s) - 1), set, :trailing),
          else: s
    end
  end

  # Python 3.9+ `str.removeprefix(p)` / `str.removesuffix(s)` — strip
  # exactly one occurrence if the prefix/suffix matches, else return
  # unchanged. Different from lstrip/rstrip (which strip a *set* of
  # chars repeatedly).
  def py_str_remove_prefix(s, prefix) when is_binary(s) and is_binary(prefix) do
    if String.starts_with?(s, prefix),
      do: binary_part(s, byte_size(prefix), byte_size(s) - byte_size(prefix)),
      else: s
  end

  def py_str_remove_suffix(s, suffix) when is_binary(s) and is_binary(suffix) do
    if String.ends_with?(s, suffix),
      do: binary_part(s, 0, byte_size(s) - byte_size(suffix)),
      else: s
  end

  # Python's `str.partition(sep)` / `str.rpartition(sep)` — split into
  # `{before, sep, after}` at the first/last occurrence of `sep`.
  # Not found: partition → `{string, "", ""}`, rpartition → `{"", "", string}`.
  def py_str_partition(s, sep) when is_binary(s) and is_binary(sep) do
    case :binary.split(s, sep) do
      [before, after_] -> {before, sep, after_}
      [^s] -> {s, "", ""}
    end
  end

  def py_str_rpartition(s, sep) when is_binary(s) and is_binary(sep) do
    case :binary.split(s, sep, [:global]) do
      [^s] ->
        {"", "", s}

      parts ->
        {init, [last]} = Enum.split(parts, -1)
        {Enum.join(init, sep), sep, last}
    end
  end

  # Python's `str.splitlines()` — split on \r\n / \r / \n; trailing
  # newline doesn't create an empty trailing entry. Empty input → [].
  def py_str_splitlines(""), do: []

  def py_str_splitlines(s) when is_binary(s) do
    s
    |> String.replace(~r/\r\n|\r/, "\n")
    |> String.split("\n")
    |> drop_trailing_empty()
  end

  def drop_trailing_empty([]), do: []

  def drop_trailing_empty(list) do
    case List.last(list) do
      "" -> Enum.slice(list, 0, length(list) - 1)
      _ -> list
    end
  end

  # Python's `.index(x)` is defined on str, list, and tuple — each with
  # the same name but different semantics (str: substring search; list
  # / tuple: equality). Pylixir's converter always emits `py_str_index`
  # regardless of receiver type, so this helper has to dispatch at
  # runtime: a non-string receiver previously raised
  # `FunctionClauseError in String.split/3` from the `py_str_find` →
  # `String.split` path.
  def py_str_index(s, sub) when is_binary(s) do
    case py_str_find(s, sub) do
      -1 -> raise RuntimeError, "substring not found"
      idx -> idx
    end
  end

  def py_str_index(list, x) when is_list(list), do: py_list_index(list, x)

  def py_str_index(tuple, x) when is_tuple(tuple),
    do: py_list_index(Tuple.to_list(tuple), x)

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

  # `itertools.chain(*iters)` — concatenate every iterable to a flat
  # list. Each iter is coerced via `py_iter_to_list` so tuples /
  # strings / ranges all work uniformly.
  def py_itertools_chain(iters) when is_list(iters),
    do: Enum.flat_map(iters, &py_iter_to_list/1)

  # `itertools.chain.from_iterable(iter_of_iters)` — same shape but
  # the args come as a single nested iterable.
  def py_itertools_chain_from_iterable(iters),
    do: iters |> py_iter_to_list() |> Enum.flat_map(&py_iter_to_list/1)

  # `itertools.accumulate(iter)` — running sums. Yields the running
  # accumulator at each step, including the first element unchanged.
  # Uses `py_add` so mixed-type accumulation (e.g. bool+int) matches
  # Python.
  def py_itertools_accumulate(iter) do
    case py_iter_to_list(iter) do
      [] ->
        []

      [first | rest] ->
        {_, acc} =
          Enum.reduce(rest, {first, [first]}, fn x, {prev, out} ->
            sum = py_add(prev, x)
            {sum, [sum | out]}
          end)

        Enum.reverse(acc)
    end
  end

  # `itertools.accumulate(iter, func)` — same shape but combine via
  # `func(prev, curr)` instead of py_add. `func` is a 2-arity fn.
  def py_itertools_accumulate_with(iter, func) when is_function(func, 2) do
    case py_iter_to_list(iter) do
      [] ->
        []

      [first | rest] ->
        {_, acc} =
          Enum.reduce(rest, {first, [first]}, fn x, {prev, out} ->
            combined = func.(prev, x)
            {combined, [combined | out]}
          end)

        Enum.reverse(acc)
    end
  end

  # `sorted(xs, key=k)` lowers to `py_sorted_by(xs, k)` so a
  # `functools.cmp_to_key`-wrapped comparator routes to `Enum.sort`
  # with the comparator semantics instead of being misused as a
  # 1-arg key function. Plain key fns fall through to `Enum.sort_by`.
  # `cmp_to_key` tags its argument as `{:py_cmp_to_key, cmp}`; the
  # pattern-match here keeps the wrap localised — call sites stay
  # unchanged.
  def py_sorted_by(xs, {:py_cmp_to_key, cmp}) when is_function(cmp, 2) do
    Enum.sort(xs, fn a, b -> cmp.(a, b) <= 0 end)
  end

  def py_sorted_by(xs, key) when is_function(key, 1) do
    Enum.sort_by(xs, key)
  end

  def py_sorted_by_desc(xs, {:py_cmp_to_key, cmp}) when is_function(cmp, 2) do
    Enum.sort(xs, fn a, b -> cmp.(a, b) >= 0 end)
  end

  def py_sorted_by_desc(xs, key) when is_function(key, 1) do
    Enum.sort_by(xs, key, :desc)
  end

  # Python's `itertools.groupby(iter)` — group CONSECUTIVE equal
  # elements. Returns a list of `{key, [elements]}` tuples that
  # destructure cleanly via `for k, g in groupby(xs)`. Strings iterate
  # as characters in Python; `py_iter_to_list` already normalises that.
  # `Enum.chunk_by/2` does the same consecutive-group split — wrap
  # each chunk as `{hd(chunk), chunk}`.
  def py_itertools_groupby(iter) do
    iter
    |> py_iter_to_list()
    |> Enum.chunk_by(& &1)
    |> Enum.map(fn group -> {hd(group), group} end)
  end

  # `itertools.groupby(iter, key)` — group by `key(elem)` rather than
  # equality on the element itself. Mirrors Python's docs note that
  # the iterable must be sorted by `key` for groups to be complete;
  # we just do the same `chunk_by` regardless and let the caller
  # handle pre-sorting (Python's behaviour is the same).
  def py_itertools_groupby_key(iter, key) when is_function(key, 1) do
    iter
    |> py_iter_to_list()
    |> Enum.chunk_by(key)
    |> Enum.map(fn group -> {key.(hd(group)), group} end)
  end

  # Python's `itertools.combinations_with_replacement(iter, r)` —
  # r-length subsets where elements may repeat (the same index can
  # be picked multiple times). Differs from `combinations` in the
  # recursion: when we pick `h`, the next pick is allowed to pick
  # `h` AGAIN, so recurse over the SAME list (`[h | t]`), not its
  # tail.
  def py_combinations_with_replacement(enum, r) when is_integer(r) and r >= 0 do
    py_cwr_inner(py_iter_to_list(enum), r)
  end

  def py_cwr_inner(_, 0), do: [[]]
  def py_cwr_inner([], _), do: []

  def py_cwr_inner([h | t] = list, r) do
    with_h = Enum.map(py_cwr_inner(list, r - 1), &[h | &1])
    without_h = py_cwr_inner(t, r)
    with_h ++ without_h
  end

  # Python's `itertools.permutations(iter)` — all orderings of the input.
  # `itertools.permutations(iter, r)` — r-length permutations.
  # Returns lists (same convention as py_combinations). Output order
  # matches CPython: lexicographic over the input's positional indices.
  def py_permutations(enum) do
    list = if is_list(enum), do: enum, else: Enum.to_list(enum)
    py_permutations(list, length(list))
  end

  def py_permutations(enum, r) when is_integer(r) and r >= 0 do
    list = if is_list(enum), do: enum, else: Enum.to_list(enum)
    py_permutations_inner(list, r)
  end

  def py_permutations_inner(_, 0), do: [[]]
  def py_permutations_inner([], _), do: []

  def py_permutations_inner(list, r) do
    Enum.flat_map(Enum.with_index(list), fn {h, i} ->
      rest = List.delete_at(list, i)
      Enum.map(py_permutations_inner(rest, r - 1), &[h | &1])
    end)
  end

  # Python's `itertools.product(*iters[, repeat=N])` — Cartesian
  # product. Output element shape: a tuple matching Python (so
  # `for a, b in product(xs, ys):` unpacks cleanly). Empty `iters`
  # yields a single empty tuple `()`, matching Python. `repeat`
  # repeats the iters list before computing the product, so
  # `product([1,2], repeat=2) == product([1,2], [1,2])`.
  def py_product(iters, repeat) when is_list(iters) and is_integer(repeat) and repeat >= 0 do
    # `List.duplicate(iters, n) |> Enum.concat()` repeats the list of
    # iters n times — concat flattens one level only (List.flatten
    # would crush the inner iters too). Then coerce each iter to a
    # list so tuples/strings/ranges all work.
    expanded =
      iters
      |> List.duplicate(repeat)
      |> Enum.concat()
      |> Enum.map(&py_iter_to_list/1)

    do_product(expanded) |> Enum.map(&List.to_tuple/1)
  end

  def do_product([]), do: [[]]

  def do_product([first | rest]) do
    tail_combos = do_product(rest)
    for x <- first, tail <- tail_combos, do: [x | tail]
  end

  # Iterate-as-list: handles Python's iter-from-string semantics
  # (each grapheme becomes an element) and tuple iteration (Tuple
  # isn't an Enumerable in Elixir). Used by the star-unpack destructure
  # path (`a, *b = expr`) and anywhere else we need a list from an
  # arbitrary Pylixir-shaped value.
  # No-op for lists — the common case, called every for-loop iter.
  def py_iter_to_list(l) when is_list(l), do: l
  def py_iter_to_list(s) when is_binary(s), do: String.graphemes(s)
  def py_iter_to_list(t) when is_tuple(t), do: Tuple.to_list(t)
  # Python iterates dicts by KEYS, not entries. `Enum.to_list/1` on a
  # map yields `[{k, v}, ...]` which is `dict.items()` shape — wrong
  # for `for k in d:`, `list(d)`, `sorted(d)`. Match Python's default.
  def py_iter_to_list(m) when is_map(m) and not is_struct(m), do: Map.keys(m)
  def py_iter_to_list(other), do: Enum.to_list(other)

  # === Slice assignment ===

  # `coll[start:stop:step] = new_seq` — replace the elements at the
  # stepped index sequence with `new_seq`. Without a step (step == nil
  # or 1), the slice is contiguous and `new_seq` length doesn't have
  # to match — extra elements extend, shorter shrinks. With a step,
  # `len(new_seq)` MUST equal the slice's index count (Python raises
  # ValueError otherwise — we mirror by overwriting positionwise).
  def py_slice_assign(list, start, stop, step, new_seq) when is_list(list) do
    step_v = step || 1
    len = length(list)
    new_seq_list = if is_list(new_seq), do: new_seq, else: Enum.to_list(new_seq)

    if step_v == 1 do
      {s, e} = py_slice_bounds(start, stop, 1, len)
      Enum.take(list, s) ++ new_seq_list ++ Enum.drop(list, e)
    else
      {s, e} = py_slice_bounds(start, stop, step_v, len)
      indices = py_slice_indices(s, e, step_v)
      py_slice_assign_stepped(list, indices, new_seq_list)
    end
  end

  def py_slice_assign_stepped(list, indices, new_seq) do
    pairs = Enum.zip(indices, new_seq) |> Map.new()
    Enum.with_index(list, fn x, i -> Map.get(pairs, i, x) end)
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

  # 3-arg form: `bisect.bisect_left(a, x, lo)` — Python defaults
  # `hi=len(a)` when omitted, so search the suffix `[lo, len(a))`.
  def py_bisect_left(list, x, lo) when is_list(list) do
    py_bisect_left(list, x, lo, length(list))
  end

  def py_bisect_right(list, x, lo) when is_list(list) do
    py_bisect_right(list, x, lo, length(list))
  end

  # 4-arg form: `bisect.bisect_left(a, x, lo, hi)` — search restricted
  # to `[lo, hi)`. Implemented by slicing then offsetting the result.
  def py_bisect_left(list, x, lo, hi) when is_list(list) do
    slice = Enum.slice(list, lo, hi - lo)
    lo + py_bisect_left(slice, x)
  end

  def py_bisect_right(list, x, lo, hi) when is_list(list) do
    slice = Enum.slice(list, lo, hi - lo)
    lo + py_bisect_right(slice, x)
  end

  # `bisect.insort(list, x)` / `bisect.insort_right(list, x)` — insert
  # `x` into the sorted `list` AFTER any existing equal entries.
  # `insort_left` inserts BEFORE. Returns the new list; the caller
  # rebinds (the in-place semantics from Python is lost since Elixir
  # lists are immutable, but the rebind via `xs = py_bisect_insort(xs, x)`
  # gives the same observable behaviour).
  def py_bisect_insort(list, x) when is_list(list) do
    py_bisect_insort_right(list, x)
  end

  def py_bisect_insort_right(list, x) when is_list(list) do
    pos = py_bisect_right(list, x)
    List.insert_at(list, pos, x)
  end

  def py_bisect_insort_left(list, x) when is_list(list) do
    pos = py_bisect_left(list, x)
    List.insert_at(list, pos, x)
  end

  # === Integer methods ===

  # Python's `int.bit_length()` — bits required to represent the int
  # in binary (excluding sign and leading zeros). `0` returns `0`;
  # negative numbers behave as their absolute value.
  def py_int_bit_length(0), do: 0
  def py_int_bit_length(n) when n < 0, do: py_int_bit_length(-n)
  def py_int_bit_length(n) when is_integer(n), do: length(Integer.digits(n, 2))

  # `type(x).__name__` — returns Python's class name as a string.
  # Discriminates booleans before integers (Python's bool is a subclass
  # but reports "bool"), and tuple before the generic struct/map
  # branches. MapSet → "set" matches the str(frozenset) tradeoff
  # already in py_str.
  def py_type_name(nil), do: "NoneType"
  def py_type_name(true), do: "bool"
  def py_type_name(false), do: "bool"
  def py_type_name(x) when is_integer(x), do: "int"
  def py_type_name(x) when is_float(x), do: "float"
  def py_type_name(x) when is_binary(x), do: "str"
  def py_type_name(x) when is_list(x), do: "list"
  def py_type_name(x) when is_tuple(x), do: "tuple"
  def py_type_name(%MapSet{}), do: "set"
  def py_type_name(x) when is_map(x), do: "dict"
  def py_type_name(x) when is_function(x), do: "function"
  def py_type_name(_), do: "object"

  # `print(*iter[, sep=..., end=...])` — unpack-then-print. Defaults
  # match Python's `print` (sep=" ", end="\n"). The lowering in
  # `Pylixir.Converter.emit_starred_call/3` routes here when the only
  # positional call argument is a Starred; sep/end_ flow through from
  # the matching kwargs there. We accept any iterable via
  # `py_iter_to_list/1` (tuples lower to Elixir tuples, etc.).
  def py_print_iter(iter, sep, end_) do
    list = py_iter_to_list(iter)
    body = list |> Enum.map(&py_str/1) |> Enum.join(sep)
    IO.write(body <> end_)
  end

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

  # === JSON encoder / decoder ===
  #
  # `json.dumps` / `json.loads`. Custom encoder because Erlang's
  # `:json.encode` (OTP 28) doesn't know about Elixir tuples or MapSets
  # and emits its own escape semantics that disagree with Python's
  # (`/` is not escaped by us; Python's default escapes nothing either).
  # Decoder routes through `:json.decode` and post-processes (binary
  # keys, json `null` → nil).

  def py_json_dumps(value), do: py_json_dumps(value, nil)

  def py_json_dumps(value, nil), do: py_json_enc(value, nil, 0) |> IO.iodata_to_binary()

  def py_json_dumps(value, indent) when is_integer(indent) and indent >= 0,
    do: py_json_enc(value, indent, 0) |> IO.iodata_to_binary()

  def py_json_enc(nil, _indent, _depth), do: "null"
  def py_json_enc(true, _indent, _depth), do: "true"
  def py_json_enc(false, _indent, _depth), do: "false"

  def py_json_enc(x, _indent, _depth) when is_integer(x),
    do: Integer.to_string(x)

  def py_json_enc(x, _indent, _depth) when is_float(x) do
    # Python prints `1.0` (not `1.0e0`); Elixir's :short matches that.
    :erlang.float_to_binary(x, [:short])
  end

  def py_json_enc(x, _indent, _depth) when is_binary(x),
    do: [?", py_json_escape(x, []), ?"]

  def py_json_enc(x, indent, depth) when is_tuple(x),
    do: py_json_enc(Tuple.to_list(x), indent, depth)

  def py_json_enc(%MapSet{} = s, indent, depth),
    do: py_json_enc(MapSet.to_list(s), indent, depth)

  def py_json_enc([], _indent, _depth), do: "[]"

  def py_json_enc(xs, indent, depth) when is_list(xs) do
    {item_sep, inner_pad, close_pad} = py_json_seps(indent, depth)
    inner = Enum.map_intersperse(xs, item_sep, &py_json_enc(&1, indent, depth + 1))
    [?[, inner_pad, inner, close_pad, ?]]
  end

  def py_json_enc(m, indent, depth) when is_map(m) and not is_struct(m) do
    case map_size(m) do
      0 ->
        "{}"

      _ ->
        # Python preserves insertion order; an Elixir map doesn't, but
        # for `json.dumps` Python sorts dict-of-string-keys by insertion.
        # We don't track insertion — fall back to key sort for stable
        # output. Numeric keys forbidden in JSON; stringify them like
        # CPython does (which always stringifies, with `sort_keys=False`
        # default).
        {item_sep, inner_pad, close_pad} = py_json_seps(indent, depth)
        kvs = m |> Map.to_list() |> Enum.sort_by(fn {k, _} -> py_json_key_str(k) end)

        inner =
          Enum.map_intersperse(kvs, item_sep, fn {k, v} ->
            [
              ?",
              py_json_escape(py_json_key_str(k), []),
              ?",
              ": ",
              py_json_enc(v, indent, depth + 1)
            ]
          end)

        [?{, inner_pad, inner, close_pad, ?}]
    end
  end

  # Python's defaults: no indent → `", "` between items, `": "` between
  # key/value, no leading newlines. Indented → `",\n<pad>"` between
  # items, items themselves prefixed with a newline + padding.
  def py_json_seps(nil, _depth), do: {", ", "", ""}

  def py_json_seps(indent, depth) when is_integer(indent) do
    item_sep = [",\n", String.duplicate(" ", indent * (depth + 1))]
    inner_pad = ["\n", String.duplicate(" ", indent * (depth + 1))]
    close_pad = ["\n", String.duplicate(" ", indent * depth)]
    {item_sep, inner_pad, close_pad}
  end

  def py_json_key_str(k) when is_binary(k), do: k
  def py_json_key_str(k) when is_integer(k), do: Integer.to_string(k)
  def py_json_key_str(k) when is_float(k), do: Float.to_string(k)
  def py_json_key_str(true), do: "true"
  def py_json_key_str(false), do: "false"
  def py_json_key_str(nil), do: "null"

  def py_json_escape(<<>>, acc), do: acc |> Enum.reverse()
  def py_json_escape(<<?"::utf8, rest::binary>>, acc), do: py_json_escape(rest, ["\\\"" | acc])
  def py_json_escape(<<?\\::utf8, rest::binary>>, acc), do: py_json_escape(rest, ["\\\\" | acc])
  def py_json_escape(<<?\n::utf8, rest::binary>>, acc), do: py_json_escape(rest, ["\\n" | acc])
  def py_json_escape(<<?\r::utf8, rest::binary>>, acc), do: py_json_escape(rest, ["\\r" | acc])
  def py_json_escape(<<?\t::utf8, rest::binary>>, acc), do: py_json_escape(rest, ["\\t" | acc])
  def py_json_escape(<<?\b::utf8, rest::binary>>, acc), do: py_json_escape(rest, ["\\b" | acc])
  def py_json_escape(<<?\f::utf8, rest::binary>>, acc), do: py_json_escape(rest, ["\\f" | acc])

  def py_json_escape(<<c::utf8, rest::binary>>, acc) when c < 0x20,
    do: py_json_escape(rest, [:io_lib.format("\\u~4.16.0b", [c]) | acc])

  def py_json_escape(<<c::utf8, rest::binary>>, acc),
    do: py_json_escape(rest, [<<c::utf8>> | acc])

  def py_json_loads(s) when is_binary(s) do
    :json.decode(s) |> py_json_normalize()
  end

  # `:json.decode` returns `:null` for JSON null; Pylixir uses nil (the
  # Python None equivalent). Booleans already match.
  def py_json_normalize(:null), do: nil
  def py_json_normalize(x) when is_list(x), do: Enum.map(x, &py_json_normalize/1)

  def py_json_normalize(x) when is_map(x) do
    Enum.into(x, %{}, fn {k, v} -> {k, py_json_normalize(v)} end)
  end

  def py_json_normalize(x), do: x

  # === Iterator protocol (`iter` / `next` / `c in it`) ===
  #
  # Pylixir doesn't model Python's full iterator protocol — but the
  # common shape `it = iter(xs); … (c in it) …` is widely used for
  # subsequence checks. The handle returned by `py_iter_make/1` is a
  # unique positive integer; the actual remaining-elements list lives
  # in the process dict under `{:pylixir_iter, ref}`. `py_in/2` has a
  # clause that recognises iterator refs and dispatches to the
  # advance-on-find semantics; `py_iter_next/1` / `py_iter_next/2`
  # cover bare `next(it)` calls.

  def py_iter_make(xs) do
    ref = :erlang.unique_integer([:positive])
    Process.put({:pylixir_iter, ref}, py_iter_to_list(xs))
    ref
  end

  def py_iter_in(c, ref) when is_integer(ref) do
    case Process.get({:pylixir_iter, ref}) do
      nil ->
        false

      list ->
        case Enum.split_while(list, fn x -> x != c end) do
          {_, []} ->
            Process.put({:pylixir_iter, ref}, [])
            false

          {_, [_ | rest]} ->
            Process.put({:pylixir_iter, ref}, rest)
            true
        end
    end
  end

  # `next(it)` / `next(it, default)` — pop the head element. Raises
  # `Pylixir.StopIteration` (a plain RuntimeError) when exhausted to
  # mirror Python's StopIteration; the 2-arg form returns `default`
  # instead.
  def py_iter_next(ref) when is_integer(ref) do
    case Process.get({:pylixir_iter, ref}) do
      nil ->
        raise RuntimeError, "StopIteration: not an iterator (ref=#{ref})"

      [] ->
        raise RuntimeError, "StopIteration"

      [h | t] ->
        Process.put({:pylixir_iter, ref}, t)
        h
    end
  end

  def py_iter_next(ref, default) when is_integer(ref) do
    case Process.get({:pylixir_iter, ref}) do
      nil ->
        default

      [] ->
        default

      [h | t] ->
        Process.put({:pylixir_iter, ref}, t)
        h
    end
  end

  # --- HELPERS END ---
end
