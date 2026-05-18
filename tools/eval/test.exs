defmodule TranslatedCode do
  @moduledoc "Church numerals"
  def py_bool_to_int(true) do
    1
  end

  def py_bool_to_int(false) do
    0
  end

  def py_bool_to_int(x) do
    x
  end

  def py_add(nil, b) do
    b
  end

  def py_add(a, nil) do
    a
  end

  def py_add(a, b) when is_boolean(a) do
    py_add(py_bool_to_int(a), b)
  end

  def py_add(a, b) when is_boolean(b) do
    py_add(a, py_bool_to_int(b))
  end

  def py_add(a, b) when is_binary(a) and is_binary(b) do
    a <> b
  end

  def py_add(a, b) when is_number(a) and is_number(b) do
    a + b
  end

  def py_add(a, b) when is_list(a) and is_list(b) do
    a ++ b
  end

  def py_add(a, b) when is_tuple(a) and is_tuple(b) do
    (Tuple.to_list(a) ++ Tuple.to_list(b)) |> List.to_tuple()
  end

  def py_add(a, b) do
    a + b
  end

  def py_sub(a, b) when is_boolean(a) do
    py_sub(py_bool_to_int(a), b)
  end

  def py_sub(a, b) when is_boolean(b) do
    py_sub(a, py_bool_to_int(b))
  end

  def py_sub(%MapSet{} = a, %MapSet{} = b) do
    MapSet.difference(a, b)
  end

  def py_sub(a, b) do
    a - b
  end

  def py_str(true) do
    "True"
  end

  def py_str(false) do
    "False"
  end

  def py_str(nil) do
    "None"
  end

  def py_str(x) when is_atom(x) do
    Atom.to_string(x)
  end

  def py_str(x) when is_list(x) do
    py_repr_list(x)
  end

  def py_str(x) when is_tuple(x) do
    py_repr_tuple(x)
  end

  def py_str(%MapSet{} = s) do
    py_repr_set(s)
  end

  def py_str(x) when is_map(x) and not is_struct(x) do
    py_repr_map(x)
  end

  def py_str(x) when is_float(x) do
    py_str_float(x)
  end

  def py_str(x) do
    to_string(x)
  end

  def py_str_float(1.0e308) do
    "inf"
  end

  def py_str_float(-1.0e308) do
    "-inf"
  end

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

  def python_sci(mantissa, exp) do
    sign =
      if exp >= 0 do
        "+"
      else
        "-"
      end

    abs_exp = abs(exp)
    exp_padded = abs_exp |> Integer.to_string() |> String.pad_leading(2, "0")
    mantissa_clean = drop_trailing_zero_decimal(mantissa)
    mantissa_clean <> "e" <> sign <> exp_padded
  end

  def drop_trailing_zero_decimal(s) do
    case String.split(s, ".") do
      [int_part, "0"] -> int_part
      _ -> s
    end
  end

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
          padded = digits <> String.duplicate("0", decimal_pos - String.length(digits))
          padded <> ".0"

        decimal_pos <= 0 ->
          leading_zeros = String.duplicate("0", -decimal_pos)
          "0." <> leading_zeros <> digits

        true ->
          {l, r} = String.split_at(digits, decimal_pos)

          r =
            if r == "" do
              "0"
            else
              r
            end

          l <> "." <> r
      end

    sign <> formatted
  end

  def py_repr_list(items) do
    "[" <> Enum.map_join(items, ", ", &py_repr/1) <> "]"
  end

  def py_repr_tuple(t) do
    items = Tuple.to_list(t)

    case items do
      [single] -> "(" <> py_repr(single) <> ",)"
      _ -> "(" <> Enum.map_join(items, ", ", &py_repr/1) <> ")"
    end
  end

  def py_repr_map(m) do
    "{" <> Enum.map_join(m, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end) <> "}"
  end

  def py_repr_set(%MapSet{} = s) do
    case MapSet.to_list(s) do
      [] -> "set()"
      items -> "{" <> Enum.map_join(items, ", ", &py_repr/1) <> "}"
    end
  end

  def py_repr(x) when is_binary(x) do
    if String.contains?(x, "'") and not String.contains?(x, "\"") do
      "\"" <> x <> "\""
    else
      "'" <> String.replace(String.replace(x, "\\", "\\\\"), "'", "\\'") <> "'"
    end
  end

  def py_repr(x) do
    py_str(x)
  end

  defp reduce(fn_arg, iter, init) do
    Enum.reduce(iter, init, fn x, acc -> fn_arg.(acc, x) end)
  end

  (
    @doc "The identity function.\n       No applications of any supplied f\n       to its argument.\n    "
    def churchZero() do
      fn f -> &identity/1 end
    end
  )

  (
    @doc "The successor of a given\n       Church numeral. One additional\n       application of f. Equivalent to\n       the arithmetic addition of one.\n    "
    def churchSucc(cn) do
      fn f -> compose(f).(cn.(f)) end
    end
  )

  (
    @doc "The arithmetic sum of two Church numerals."
    def churchAdd(m) do
      fn n -> fn f -> compose(m.(f)).(n.(f)) end end
    end
  )

  (
    @doc "The arithmetic product of two Church numerals."
    def churchMult(m) do
      fn n -> compose(m).(n) end
    end
  )

  (
    @doc "Exponentiation of Church numerals. m^n"
    def churchExp(m) do
      fn n -> n.(m) end
    end
  )

  (
    @doc "The integer equivalent of a\n       given Church numeral.\n    "
    def intFromChurch(cn) do
      cn.(&succ/1).(0)
    end
  )

  (
    @doc "A left to right composition of two\n       functions f and g"
    def compose(f) do
      fn g -> fn x -> g.(f.(x)) end end
    end
  )

  (
    @doc "Left to right reduction of a list,\n       using the binary operator f, and\n       starting with an initial value a.\n    "
    def foldl(f) do
      go = fn acc, xs -> reduce(fn a, x -> f.(a).(x) end, xs, acc) end
      fn acc -> fn xs -> go.(acc, xs) end end
    end
  )

  (
    @doc "The identity function."
    def identity(x) do
      x
    end
  )

  (
    @doc "The successor of a value.\n       For numeric types, (1 +).\n    "
    def succ(x) do
      if is_integer(x) || is_boolean(x) do
        py_add(1, x)
      else
        List.to_string([1 + hd(String.to_charlist(x))])
      end
    end
  )

  def py_main do
    try do
      repeat = fn elem, times -> List.duplicate(elem, times) end
      nil
      replicate = fn n -> fn x -> List.duplicate(x, n) end end
      churchFromInt = fn n -> fn f -> foldl(&compose/1).(&identity/1).(replicate.(n).(f)) end end

      churchFromInt_ = fn n ->
        try do
          if 0 == n do
            throw({:pylixir_return, churchZero()})
          else
            throw({:pylixir_return, churchSucc(churchFromInt.(py_sub(n, 1)))})
          end
        catch
          :throw, {:pylixir_return, val} -> val
        end
      end

      main = fn ->
        cThree = churchFromInt.(3)
        cFour = churchFromInt.(4)

        IO.write(
          py_str(
            Enum.map(
              [
                churchAdd(cThree).(cFour),
                churchMult(cThree).(cFour),
                churchExp(cFour).(cThree),
                churchExp(cThree).(cFour)
              ],
              &intFromChurch/1
            )
          ) <> "\n"
        )
      end

      if "__main__" == "__main__" do
        main.()
      end
    catch
      :throw, {:pylixir_exit, code} -> code
    end
  end
end

TranslatedCode.py_main()