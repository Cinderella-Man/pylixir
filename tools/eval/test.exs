defmodule TranslatedCode do
  @moduledoc "Church numerals"
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

  def py_str(x) do
    to_string(x)
  end

  def py_repr(x) when is_binary(x) do
    if String.contains?(x, "'") and not String.contains?(x, "\"") do
      "\"" <> x <> "\""
    else
      "'" <> String.replace(String.replace(x, "\\", "\\\\"), "'", "\\'") <> "'"
    end
  end

  def py_repr(x) when is_list(x) do
    "[" <> Enum.map_join(x, ", ", &py_repr/1) <> "]"
  end

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
    "{" <> Enum.map_join(x, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end) <> "}"
  end

  def py_repr(x) do
    py_str(x)
  end

  @doc "The identity function.\n       No applications of any supplied f\n       to its argument.\n    "
  def churchZero() do
    fn f -> &identity/1 end
  end

  @doc "The successor of a given\n       Church numeral. One additional\n       application of f. Equivalent to\n       the arithmetic addition of one.\n    "
  def churchSucc(cn) do
    fn f -> compose(f).(cn.(f)) end
  end

  @doc "The arithmetic sum of two Church numerals."
  def churchAdd(m) do
    fn n -> fn f -> compose(m.(f)).(n.(f)) end end
  end

  @doc "The arithmetic product of two Church numerals."
  def churchMult(m) do
    fn n -> compose(m).(n) end
  end

  @doc "Exponentiation of Church numerals. m^n"
  def churchExp(m) do
    fn n -> n.(m) end
  end

  @doc "The integer equivalent of a\n       given Church numeral.\n    "
  def intFromChurch(cn) do
    cn.(&succ/1).(0)
  end

  @doc "A left to right composition of two\n       functions f and g"
  def compose(f) do
    fn g -> fn x -> g.(f.(x)) end end
  end

  @doc "Left to right reduction of a list,\n       using the binary operator f, and\n       starting with an initial value a.\n    "
  def foldl(f) do
    go = fn acc, xs -> Enum.reduce(xs, acc, fn x, a -> f.(a).(x) end) end
    fn acc -> fn xs -> go.(acc, xs) end end
  end

  @doc "The identity function."
  def identity(x) do
    x
  end

  @doc "The successor of a value.\n       For numeric types, (1 +).\n    "
  def succ(x) do
    if is_integer(x) || is_boolean(x) do
      1 + x
    else
      List.to_string([1 + hd(String.to_charlist(x))])
    end
  end

  def py_main do
    replicate = fn n -> fn x -> List.duplicate(x, n) end end
    churchFromInt = fn n -> fn f -> foldl(&compose/1).(&identity/1).(replicate.(n).(f)) end end

    main = fn ->
      cThree = churchFromInt.(3)
      cFour = churchFromInt.(4)

      IO.write(
        py_repr(
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

    main.()
  end
end

TranslatedCode.py_main()