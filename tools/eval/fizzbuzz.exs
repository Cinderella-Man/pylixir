defmodule TranslatedCode do
  def py_mod(a, args) when is_binary(a) do
    arg_list =
      cond do
        is_tuple(args) -> Tuple.to_list(args)
        true -> [args]
      end

    py_str_percent_format(a, arg_list, [])
  end

  def py_mod(a, b) when is_integer(a) and is_integer(b) do
    Integer.mod(a, b)
  end

  def py_mod(a, b) when is_number(a) and is_number(b) do
    a - b * :math.floor(a / b)
  end

  def py_str_percent_format("", _args, out) do
    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  def py_str_percent_format("%%" <> rest, args, out) do
    py_str_percent_format(rest, args, ["%" | out])
  end

  def py_str_percent_format("%" <> rest, args, out) do
    {spec, rest} = parse_percent_spec(rest, "")
    [arg | tail_args] = args
    formatted = format_percent_value(spec, arg)
    py_str_percent_format(rest, tail_args, [formatted | out])
  end

  def py_str_percent_format(<<ch::utf8, rest::binary>>, args, out) do
    py_str_percent_format(rest, args, [<<ch::utf8>> | out])
  end

  def parse_percent_spec(<<ch::utf8, rest::binary>>, acc) do
    if (ch >= 97 and ch <= 122) or (ch >= 65 and ch <= 90) do
      {acc <> <<ch::utf8>>, rest}
    else
      parse_percent_spec(rest, acc <> <<ch::utf8>>)
    end
  end

  def parse_percent_spec("", acc) do
    {acc, ""}
  end

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

  def parse_percent_flags(<<45, rest::binary>>, flags) do
    parse_percent_flags(rest, %{flags | left: true})
  end

  def parse_percent_flags(<<48, rest::binary>>, flags) do
    parse_percent_flags(rest, %{flags | zero: true})
  end

  def parse_percent_flags(<<43, rest::binary>>, flags) do
    parse_percent_flags(rest, %{flags | plus: true})
  end

  def parse_percent_flags(<<32, rest::binary>>, flags) do
    parse_percent_flags(rest, %{flags | space: true})
  end

  def parse_percent_flags(rest, flags) do
    {flags, rest}
  end

  def parse_percent_int(<<ch, rest::binary>>, acc) when ch >= 48 and ch <= 57 do
    parse_percent_int(rest, acc * 10 + (ch - 48))
  end

  def parse_percent_int(rest, acc) do
    {acc, rest}
  end

  def parse_percent_precision(<<46, rest::binary>>) do
    {p, rest} = parse_percent_int(rest, 0)
    {p, rest}
  end

  def parse_percent_precision(rest) do
    {nil, rest}
  end

  def format_percent_typed("d", v, _p) when is_integer(v) do
    Integer.to_string(abs(v))
  end

  def format_percent_typed("d", v, _p) when is_float(v) do
    Integer.to_string(abs(trunc(v)))
  end

  def format_percent_typed("i", v, p) do
    format_percent_typed("d", v, p)
  end

  def format_percent_typed("s", v, nil) do
    py_str(v)
  end

  def format_percent_typed("s", v, p) when is_integer(p) do
    v |> py_str() |> String.slice(0, p)
  end

  def format_percent_typed("f", v, nil) do
    v_f =
      if is_integer(v) do
        v * 1.0
      else
        v
      end

    :erlang.float_to_binary(v_f, decimals: 6)
  end

  def format_percent_typed("f", v, p) when is_integer(p) do
    v_f =
      if is_integer(v) do
        v * 1.0
      else
        v
      end

    :erlang.float_to_binary(v_f, decimals: p)
  end

  def format_percent_typed("e", v, p) do
    v_f =
      if is_integer(v) do
        v * 1.0
      else
        v
      end

    digits =
      if is_integer(p) do
        p
      else
        6
      end

    :erlang.float_to_binary(v_f, scientific: digits)
  end

  def format_percent_typed("x", v, _p) when is_integer(v) do
    v |> abs() |> Integer.to_string(16) |> String.downcase()
  end

  def format_percent_typed("X", v, _p) when is_integer(v) do
    v |> abs() |> Integer.to_string(16)
  end

  def format_percent_typed("o", v, _p) when is_integer(v) do
    v |> abs() |> Integer.to_string(8)
  end

  def format_percent_typed("b", v, _p) when is_integer(v) do
    v |> abs() |> Integer.to_string(2)
  end

  def format_percent_typed("c", v, _p) when is_integer(v) do
    <<v::utf8>>
  end

  def format_percent_typed("c", v, _p) when is_binary(v) do
    v
  end

  def format_percent_typed("r", v, _p) do
    py_repr(v)
  end

  def format_percent_typed(_, v, _p) do
    py_str(v)
  end

  def apply_percent_sign(s, v, flags, type) when type in ["d", "i", "f", "e"] and is_number(v) do
    cond do
      v < 0 -> "-" <> s
      flags.plus -> "+" <> s
      flags.space -> " " <> s
      true -> s
    end
  end

  def apply_percent_sign(s, _v, _flags, _type) do
    s
  end

  def apply_percent_pad(s, width, flags) when width > 0 do
    diff = width - String.length(s)

    cond do
      diff <= 0 -> s
      flags.left -> s <> String.duplicate(" ", diff)
      flags.zero -> apply_zero_pad(s, diff)
      true -> String.duplicate(" ", diff) <> s
    end
  end

  def apply_percent_pad(s, _width, _flags) do
    s
  end

  def apply_zero_pad("-" <> rest, diff) do
    "-" <> String.duplicate("0", diff) <> rest
  end

  def apply_zero_pad("+" <> rest, diff) do
    "+" <> String.duplicate("0", diff) <> rest
  end

  def apply_zero_pad(s, diff) do
    String.duplicate("0", diff) <> s
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
    py_repr(x)
  end

  def py_str(x) when is_tuple(x) do
    py_repr(x)
  end

  def py_str(%MapSet{} = s) do
    py_repr(s)
  end

  def py_str(x) when is_map(x) and not is_struct(x) do
    py_repr(x)
  end

  def py_str(x) do
    to_string(x)
  end

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
          cp <= 8 or cp == 11 or cp == 12 or (cp >= 14 and cp <= 31) ->
            "\\x" <>
              (cp |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0"))

          cp >= 127 and cp <= 159 ->
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

  def py_repr(x) when is_list(x) do
    "[" <> Enum.map_join(x, ", ", &py_repr/1) <> "]"
  end

  def py_repr(x) do
    py_str(x)
  end

  def py_main do
    Enum.each(Enum.to_list(1..15//1), fn i ->
      cond do
        py_mod(i, 15) == 0 -> IO.write("FizzBuzz" <> "\n")
        py_mod(i, 3) == 0 -> IO.write("Fizz" <> "\n")
        py_mod(i, 5) == 0 -> IO.write("Buzz" <> "\n")
        true -> IO.write(Integer.to_string(i) <> "\n")
      end
    end)
  end
end

TranslatedCode.py_main()