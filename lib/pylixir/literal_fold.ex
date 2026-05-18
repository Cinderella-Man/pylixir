defmodule Pylixir.LiteralFold do
  @moduledoc """
  Compile-time evaluation of Python literal expressions to BEAM terms.

  Used in two places:

    * `Pylixir.ModuleAnalysis` to gate promotion of top-level `Assign`s
      to `@var_<name>` module attributes — only foldable values qualify,
      because module-attribute scope can't reference runtime helpers
      like `py_pow/2` or `py_sub/2`.
    * `Pylixir.Converter.convert_module_attrs/2` to emit the folded
      literal directly rather than the equivalent runtime expression.

  Surface is intentionally narrow: Constants, container literals
  (List/Tuple/Dict/Set) recursively over foldable, and arithmetic /
  bitwise / logical ops on foldable scalars. Anything outside this
  surface returns `:error` and callers should fall back.
  """

  @doc """
  Try to evaluate `node` to a BEAM term at compile time. Returns
  `{:ok, value}` or `:error`.
  """
  @spec fold(map()) :: {:ok, term()} | :error
  def fold(%{"_type" => "Constant", "value" => v}), do: {:ok, v}

  def fold(%{"_type" => "List", "elts" => elts}), do: fold_each(elts)

  def fold(%{"_type" => "Tuple", "elts" => elts}) do
    with {:ok, list} <- fold_each(elts), do: {:ok, List.to_tuple(list)}
  end

  def fold(%{"_type" => "Set", "elts" => elts}) do
    with {:ok, list} <- fold_each(elts), do: {:ok, MapSet.new(list)}
  end

  def fold(%{"_type" => "Dict", "keys" => ks, "values" => vs}) do
    with {:ok, kvs} <- fold_each(ks),
         {:ok, vvs} <- fold_each(vs) do
      {:ok, Enum.zip(kvs, vvs) |> Map.new()}
    end
  end

  def fold(%{"_type" => "UnaryOp", "op" => op, "operand" => operand}) do
    with {:ok, val} <- fold(operand),
         {:ok, op_name} <- unary_op(op) do
      apply_unary(op_name, val)
    end
  end

  def fold(%{"_type" => "BinOp", "op" => op, "left" => l, "right" => r}) do
    with {:ok, lv} <- fold(l),
         {:ok, rv} <- fold(r),
         {:ok, op_name} <- bin_op(op) do
      apply_bin(op_name, lv, rv)
    end
  end

  def fold(_), do: :error

  defp fold_each(nodes), do: do_fold_each(nodes, [])

  defp do_fold_each([], acc), do: {:ok, Enum.reverse(acc)}

  defp do_fold_each([n | rest], acc) do
    case fold(n) do
      {:ok, v} -> do_fold_each(rest, [v | acc])
      :error -> :error
    end
  end

  defp unary_op(%{"_type" => "USub"}), do: {:ok, :usub}
  defp unary_op(%{"_type" => "UAdd"}), do: {:ok, :uadd}
  defp unary_op(%{"_type" => "Not"}), do: {:ok, :not}
  defp unary_op(%{"_type" => "Invert"}), do: {:ok, :invert}
  defp unary_op(_), do: :error

  defp apply_unary(:usub, v) when is_number(v), do: {:ok, -v}
  defp apply_unary(:uadd, v) when is_number(v), do: {:ok, +v}
  defp apply_unary(:not, v), do: {:ok, not truthy?(v)}
  defp apply_unary(:invert, v) when is_integer(v), do: {:ok, Bitwise.bnot(v)}
  defp apply_unary(_, _), do: :error

  defp bin_op(%{"_type" => "Add"}), do: {:ok, :add}
  defp bin_op(%{"_type" => "Sub"}), do: {:ok, :sub}
  defp bin_op(%{"_type" => "Mult"}), do: {:ok, :mult}
  defp bin_op(%{"_type" => "Div"}), do: {:ok, :div}
  defp bin_op(%{"_type" => "FloorDiv"}), do: {:ok, :floor_div}
  defp bin_op(%{"_type" => "Mod"}), do: {:ok, :mod}
  defp bin_op(%{"_type" => "Pow"}), do: {:ok, :pow}
  defp bin_op(%{"_type" => "BitAnd"}), do: {:ok, :band}
  defp bin_op(%{"_type" => "BitOr"}), do: {:ok, :bor}
  defp bin_op(%{"_type" => "BitXor"}), do: {:ok, :bxor}
  defp bin_op(%{"_type" => "LShift"}), do: {:ok, :lshift}
  defp bin_op(%{"_type" => "RShift"}), do: {:ok, :rshift}
  defp bin_op(_), do: :error

  defp apply_bin(:add, a, b) when is_number(a) and is_number(b), do: {:ok, a + b}
  defp apply_bin(:add, a, b) when is_binary(a) and is_binary(b), do: {:ok, a <> b}
  defp apply_bin(:add, a, b) when is_list(a) and is_list(b), do: {:ok, a ++ b}
  defp apply_bin(:sub, a, b) when is_number(a) and is_number(b), do: {:ok, a - b}
  defp apply_bin(:mult, a, b) when is_number(a) and is_number(b), do: {:ok, a * b}

  defp apply_bin(:mult, a, b) when is_binary(a) and is_integer(b) and b >= 0,
    do: {:ok, String.duplicate(a, b)}

  defp apply_bin(:mult, a, b) when is_integer(a) and is_binary(b) and a >= 0,
    do: {:ok, String.duplicate(b, a)}

  defp apply_bin(:div, a, b) when is_number(a) and is_number(b) and b != 0,
    do: {:ok, a / b}

  defp apply_bin(:floor_div, a, b) when is_integer(a) and is_integer(b) and b != 0,
    do: {:ok, Integer.floor_div(a, b)}

  defp apply_bin(:mod, a, b) when is_integer(a) and is_integer(b) and b != 0,
    do: {:ok, Integer.mod(a, b)}

  defp apply_bin(:pow, a, b) when is_integer(a) and is_integer(b) and b >= 0,
    do: {:ok, Integer.pow(a, b)}

  defp apply_bin(:band, a, b) when is_integer(a) and is_integer(b), do: {:ok, Bitwise.band(a, b)}
  defp apply_bin(:bor, a, b) when is_integer(a) and is_integer(b), do: {:ok, Bitwise.bor(a, b)}
  defp apply_bin(:bxor, a, b) when is_integer(a) and is_integer(b), do: {:ok, Bitwise.bxor(a, b)}

  defp apply_bin(:lshift, a, b) when is_integer(a) and is_integer(b) and b >= 0,
    do: {:ok, Bitwise.bsl(a, b)}

  defp apply_bin(:rshift, a, b) when is_integer(a) and is_integer(b) and b >= 0,
    do: {:ok, Bitwise.bsr(a, b)}

  defp apply_bin(_, _, _), do: :error

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(0), do: false
  defp truthy?(+0.0), do: false
  defp truthy?(-0.0), do: false
  defp truthy?(""), do: false
  defp truthy?([]), do: false
  defp truthy?(_), do: true

  @doc """
  Compute Python's `repr(value)` for a BEAM term at compile time.

  Same surface as `Pylixir.RuntimeHelpers.py_repr/1` but operates on the
  already-materialised BEAM term (post-`fold/1`). Returns `:error` for
  shapes we don't support — floats, nested non-foldable values, structs
  other than `MapSet`. The runtime path stays correct for the `:error`
  fallback.

  Algorithm mirrored from the runtime helper after the escape-table
  fix; this is the single source of truth (the runtime clause
  delegates back here to keep behaviour identical).
  """
  @spec repr_of(term()) :: {:ok, binary()} | :error
  def repr_of(true), do: {:ok, "True"}
  def repr_of(false), do: {:ok, "False"}
  def repr_of(nil), do: {:ok, "None"}
  def repr_of(v) when is_integer(v), do: {:ok, Integer.to_string(v)}
  def repr_of(v) when is_binary(v), do: {:ok, str_repr(v)}

  def repr_of(v) when is_list(v), do: fold_seq(v, "[", "]")

  def repr_of(v) when is_tuple(v) and tuple_size(v) == 1 do
    with {:ok, r} <- repr_of(elem(v, 0)), do: {:ok, "(" <> r <> ",)"}
  end

  def repr_of(v) when is_tuple(v), do: fold_seq(Tuple.to_list(v), "(", ")")

  def repr_of(%MapSet{} = s) do
    case MapSet.to_list(s) do
      [] -> {:ok, "set()"}
      xs -> fold_seq(xs, "{", "}")
    end
  end

  def repr_of(v) when is_map(v) and not is_struct(v) do
    with {:ok, pairs} <- fold_pairs(Map.to_list(v)),
         do: {:ok, "{" <> Enum.join(pairs, ", ") <> "}"}
  end

  # Floats / structs / pids / refs / functions — runtime handles these.
  def repr_of(_), do: :error

  @doc """
  Compute Python's `str(value)` for a BEAM term at compile time.

  Identical to `repr_of/1` for every type EXCEPT binary, where `str()`
  returns the string unchanged (no quotes, no escapes — Python's `str`
  of a string is the identity).
  """
  @spec str_of(term()) :: {:ok, binary()} | :error
  def str_of(v) when is_binary(v), do: {:ok, v}
  def str_of(v), do: repr_of(v)

  @doc """
  Compute Python's `repr()` of a single string. Chooses single vs.
  double quotes the way Python does (prefer single; switch to double
  when the string contains `'` and no `"`) and applies the full
  Python escape table.

  Used both as `repr_of/1`'s binary clause and (after Q4 back-port) as
  the runtime `py_repr/1` and `py_repr_str/1` binary implementations.
  """
  @spec str_repr(binary()) :: binary()
  def str_repr(s) when is_binary(s) do
    escaped = str_escape_body(s)
    has_single = String.contains?(escaped, "'")
    has_double = String.contains?(escaped, "\"")

    if has_single and not has_double do
      "\"" <> escaped <> "\""
    else
      "'" <> String.replace(escaped, "'", "\\'") <> "'"
    end
  end

  # Python-correct escape table. Three observations to get right:
  #
  # 1. Backslash MUST be replaced FIRST, otherwise the `\\xNN` we
  #    insert later would be re-escaped to `\\\\xNN`.
  # 2. Python's repr uses named-escape sequences ONLY for `\n` `\t`
  #    `\r` (and `\\` `\'` `\"`). Despite C / many other languages,
  #    `\a` (0x07), `\b` (0x08), `\f` (0x0c), `\v` (0x0b) are NOT
  #    named in Python repr output — they emit as `\x07`/`\x08`/etc.
  # 3. All other C0 controls (0x00-0x1F minus the three named) and
  #    all of C1 (0x7F-0x9F) emit as `\xNN` with two lowercase hex
  #    digits.
  #
  # Applied to the string body BEFORE the quote-choice in `str_repr/1`.
  defp str_escape_body(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
    |> hex_escape_remaining_controls()
  end

  defp hex_escape_remaining_controls(s) do
    for <<cp::utf8 <- s>>, into: "" do
      cond do
        # C0 controls minus the three already named (0x09 \t, 0x0A
        # \n, 0x0D \r): full 0x00-0x1F range except those three.
        cp <= 0x08 or cp == 0x0B or cp == 0x0C or (cp >= 0x0E and cp <= 0x1F) ->
          hex_byte(cp)

        # DEL + C1 controls (0x7F-0x9F). Higher printable Unicode is
        # left as-is — Python repr keeps printable codepoints raw.
        cp >= 0x7F and cp <= 0x9F ->
          hex_byte(cp)

        true ->
          <<cp::utf8>>
      end
    end
  end

  defp hex_byte(cp) do
    "\\x" <> (cp |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0"))
  end

  # `fold_seq([1, 2, 3], "[", "]") -> {:ok, "[1, 2, 3]"}`. Recursively
  # repr's each element; halts on the first `:error`.
  defp fold_seq(items, open, close) do
    items
    |> Enum.reduce_while({:ok, []}, fn elem, {:ok, acc} ->
      case repr_of(elem) do
        {:ok, r} -> {:cont, {:ok, [r | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, open <> Enum.join(Enum.reverse(rev), ", ") <> close}
      :error -> :error
    end
  end

  # Each key + value through `repr_of/1`; pair joined by `": "`.
  defp fold_pairs(kvs) do
    kvs
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      with {:ok, kr} <- repr_of(k),
           {:ok, vr} <- repr_of(v) do
        {:cont, {:ok, [kr <> ": " <> vr | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      :error -> :error
    end
  end
end
