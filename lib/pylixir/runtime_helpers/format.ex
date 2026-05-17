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

  def py_center_pad(s, width, fill) do
    diff = width - String.length(s)
    if diff <= 0 do
      s
    else
      left = div(diff, 2)
      right = diff - left
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

  # --- HELPERS END ---

  # Standalone-module test surface: forward py_str to the core
  # RuntimeHelpers so this module is callable in isolation.
  # (In the splice, py_str is already in scope from the core helpers.)
  defp py_str(v), do: Pylixir.RuntimeHelpers.py_str(v)
end
