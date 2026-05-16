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
end
