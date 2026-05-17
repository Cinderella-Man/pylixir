defmodule Pylixir.RuntimeHelpers.Format do
  @moduledoc """
  Runtime helpers for Python f-string format-spec interpretation.
  Lives in its own file because the spec parser is ~80 lines of
  regex-based dispatch that's logically separate from arithmetic /
  collection / conversion core. The lowering-time emitter is
  `Pylixir.Nodes.FString`.

  All defs in this module are spliced into every generated
  `TranslatedCode` module via `Pylixir.HelpersCodegen` (between the
  sentinel comments below). ExUnit can also call them directly via
  `Pylixir.RuntimeHelpers.Format.py_format_value/2`.
  """

  # --- HELPERS START ---

  # Python f-string format spec interpretation. Spec syntax (subset):
  #
  #   [fill][align][sign][#][0][width][,][.precision][type]
  #
  # Supports the common cases used in competitive code:
  #
  #   * `02d` / `4d`         — int with width + optional zero-pad
  #   * `.2f` / `8.3f`       — float with fixed precision + width
  #   * `>5` / `<5` / `^5`   — alignment with space fill (or `0` for zero)
  #   * `s`                  — string (identity after py_str)
  #
  # Falls back to `py_str/1` for anything we don't recognise.
  def py_format_value(value, spec) when is_binary(spec) do
    case parse_format_spec(spec) do
      {:int, width, pad_char} when is_integer(value) ->
        Integer.to_string(value) |> String.pad_leading(width, pad_char)

      {:int_signed, width, pad_char} when is_integer(value) ->
        sign = if value >= 0, do: "+", else: "-"
        body = Integer.to_string(abs(value))
        (sign <> body) |> String.pad_leading(width, pad_char)

      {:int_base, base, width, pad_char} when is_integer(value) ->
        Integer.to_string(value, base) |> String.downcase() |> String.pad_leading(width, pad_char)

      {:int_base_upper, base, width, pad_char} when is_integer(value) ->
        Integer.to_string(value, base) |> String.pad_leading(width, pad_char)

      {:int_comma} when is_integer(value) ->
        value |> Integer.to_string() |> insert_thousands_separators(",")

      {:float, width, precision} ->
        v = if is_integer(value), do: value * 1.0, else: value
        s = :erlang.float_to_binary(v, decimals: precision)
        if width > 0, do: String.pad_leading(s, width, " "), else: s

      {:align, :right, width, fill} ->
        s = if is_binary(value), do: value, else: py_str(value)
        String.pad_leading(s, width, fill)

      {:align, :left, width, fill} ->
        s = if is_binary(value), do: value, else: py_str(value)
        String.pad_trailing(s, width, fill)

      {:align, :center, width, fill} ->
        s = if is_binary(value), do: value, else: py_str(value)
        py_center_pad(s, width, fill)

      :string ->
        if is_binary(value), do: value, else: py_str(value)

      _ ->
        py_str(value)
    end
  end

  # Insert a separator every 3 digits from the right. `"1234567"` → `"1,234,567"`.
  # Handles an optional leading "-" so negative numbers format correctly.
  def insert_thousands_separators(s, sep) when is_binary(s) and is_binary(sep) do
    {sign, body} =
      case s do
        "-" <> rest -> {"-", rest}
        other -> {"", other}
      end

    sign <>
      (body
       |> String.reverse()
       |> String.graphemes()
       |> Enum.chunk_every(3)
       |> Enum.map_join(sep, &Enum.join/1)
       |> String.reverse())
  end

  def py_center_pad(s, width, fill) do
    diff = width - String.length(s)
    if diff <= 0 do
      s
    else
      # Python's str.center puts the extra pad-char on the LEFT when
      # `diff` is odd (e.g. `"ab".center(7, "-") == "---ab--"`), not
      # the right. Computing right first gets the math right.
      right = div(diff, 2)
      left = diff - right
      String.duplicate(fill, left) <> s <> String.duplicate(fill, right)
    end
  end

  # Parse subset of Python format spec. Returns a tagged tuple the
  # runtime helper switches on.
  def parse_format_spec(spec) do
    cond do
      # `0Nd` — zero-pad int, width N
      Regex.run(~r/^0(\d+)d$/, spec) ->
        [_, n] = Regex.run(~r/^0(\d+)d$/, spec)
        {:int, String.to_integer(n), "0"}

      # `Nd` — width N int, space-pad
      Regex.run(~r/^(\d+)d$/, spec) ->
        [_, n] = Regex.run(~r/^(\d+)d$/, spec)
        {:int, String.to_integer(n), " "}

      # `d` alone — just to_string for int
      spec == "d" ->
        {:int, 0, " "}

      # `+d` / `+Nd` — always-show-sign int. Padding goes around the
      # sign+digits combo. (Doesn't yet handle `0+Nd` zero-pad-with-sign.)
      Regex.run(~r/^\+(\d*)d?$/, spec) ->
        [_, w] = Regex.run(~r/^\+(\d*)d?$/, spec)
        width = if w == "", do: 0, else: String.to_integer(w)
        {:int_signed, width, " "}

      # `Nb` / `0Nb` — binary; `Nx` / `NX` — hex; `No` — octal.
      Regex.run(~r/^(0?)(\d*)([bxXo])$/, spec) ->
        [_, zero, w, type] = Regex.run(~r/^(0?)(\d*)([bxXo])$/, spec)
        width = if w == "", do: 0, else: String.to_integer(w)
        pad = if zero == "0", do: "0", else: " "

        base =
          case type do
            "b" -> 2
            "o" -> 8
            _ -> 16
          end

        case type do
          "X" -> {:int_base_upper, base, width, pad}
          _ -> {:int_base, base, width, pad}
        end

      # `,` — thousands separator for int.
      spec == "," ->
        {:int_comma}

      # `[width].precisionf` — float
      Regex.run(~r/^(\d*)\.(\d+)f$/, spec) ->
        [_, w, p] = Regex.run(~r/^(\d*)\.(\d+)f$/, spec)
        width = if w == "", do: 0, else: String.to_integer(w)
        {:float, width, String.to_integer(p)}

      # `.Nf` short
      Regex.run(~r/^\.(\d+)f$/, spec) ->
        [_, p] = Regex.run(~r/^\.(\d+)f$/, spec)
        {:float, 0, String.to_integer(p)}

      # `>N` / `<N` / `^N` with optional fill char
      Regex.run(~r/^(.?)([<>^])(\d+)$/, spec) ->
        [_, fill, align, width] = Regex.run(~r/^(.?)([<>^])(\d+)$/, spec)
        fill_char = if fill == "", do: " ", else: fill

        align_atom =
          case align do
            "<" -> :left
            ">" -> :right
            "^" -> :center
          end

        {:align, align_atom, String.to_integer(width), fill_char}

      spec == "s" or spec == "" ->
        :string

      true ->
        :unknown
    end
  end

  # Python's `str.format_map(mapping)` — like `.format(**mapping)` but
  # the mapping is a runtime value. We parse the template at runtime
  # (no compile-time placeholder resolution like `.format(...)` gets).
  # Supports `{name}` and `{name:spec}`; positional / auto-numbered
  # placeholders are *not* supported (Python's docs say format_map is
  # specifically for named lookups). Missing keys raise KeyError to
  # mirror Python.
  def py_str_format_map(template, mapping) when is_binary(template) and is_map(mapping) do
    template
    |> parse_template_runtime("", [])
    |> Enum.map(fn
      {:text, t} -> t
      {:placeholder, name, nil} -> py_str(format_map_fetch!(mapping, name))
      {:placeholder, name, spec} -> py_format_value(format_map_fetch!(mapping, name), spec)
    end)
    |> Enum.join()
  end

  def format_map_fetch!(mapping, name) do
    case Map.fetch(mapping, name) do
      {:ok, v} -> v
      :error -> raise KeyError, key: name
    end
  end

  def parse_template_runtime("", acc_text, acc),
    do: Enum.reverse(format_map_prepend_text(acc_text, acc))

  def parse_template_runtime("{{" <> rest, acc_text, acc),
    do: parse_template_runtime(rest, acc_text <> "{", acc)

  def parse_template_runtime("}}" <> rest, acc_text, acc),
    do: parse_template_runtime(rest, acc_text <> "}", acc)

  def parse_template_runtime("{" <> rest, acc_text, acc) do
    case String.split(rest, "}", parts: 2) do
      [body, after_brace] ->
        {name, spec} =
          case String.split(body, ":", parts: 2) do
            [n] -> {n, nil}
            [n, s] -> {n, s}
          end

        acc = format_map_prepend_text(acc_text, acc)
        parse_template_runtime(after_brace, "", [{:placeholder, name, spec} | acc])

      _ ->
        raise ArgumentError, "unbalanced `{` in format_map template"
    end
  end

  def parse_template_runtime(<<ch::utf8, rest::binary>>, acc_text, acc),
    do: parse_template_runtime(rest, acc_text <> <<ch::utf8>>, acc)

  def format_map_prepend_text("", acc), do: acc
  def format_map_prepend_text(text, acc), do: [{:text, text} | acc]

  # --- HELPERS END ---

  # Standalone-module test surface: forward py_str to the core
  # RuntimeHelpers so this module is callable in isolation.
  # (In the splice, py_str is already in scope from the core helpers.)
  defp py_str(v), do: Pylixir.RuntimeHelpers.py_str(v)
end
