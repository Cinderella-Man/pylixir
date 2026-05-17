defmodule Pylixir.Nodes.FString do
  @moduledoc """
  Owns the lowering for Python f-strings (`JoinedStr` + `FormattedValue`
  AST nodes).

  Strategy:

    * Plain `Constant` parts (`"abc"`) emit as their binary value.
    * `FormattedValue` parts emit as `py_str(value)` for the no-spec
      case, or `py_format_value(value, "spec")` when a constant format
      spec is present (`f"{x:.2f}"`). The runtime helper parses the
      spec at runtime — see `py_format_value/2` / `parse_format_spec/1`
      in `Pylixir.RuntimeHelpers`.
    * Nested-interpolation specs (`f"{x:.{w}f}"`) raise — the runtime
      helper takes a literal spec string.

  All parts are joined with `<>`. The runtime spec-parser is the
  contract surface; this module is just the codegen-time shape
  extractor.
  """

  alias Pylixir.{Converter, UnsupportedNodeError}

  @spec joined_str(map(), Pylixir.Context.t()) :: {Macro.t(), Pylixir.Context.t()}
  def joined_str(%{"_type" => "JoinedStr", "values" => values}, context) do
    {parts, context} =
      Enum.reduce(values, {[], context}, fn part, {acc, ctx} ->
        {ast, ctx} = part(part, ctx)
        {[ast | acc], ctx}
      end)

    parts = Enum.reverse(parts)

    ast =
      case parts do
        [] -> ""
        [single] -> single
        [first | rest] -> Enum.reduce(rest, first, fn p, acc -> {:<>, [], [acc, p]} end)
      end

    {ast, context}
  end

  # --- JoinedStr part dispatch -----------------------------------------

  defp part(%{"_type" => "Constant", "value" => v}, context) when is_binary(v),
    do: {v, context}

  defp part(%{"_type" => "FormattedValue"} = node, context) do
    {value_ast, context} = Converter.convert(Map.fetch!(node, "value"), context)
    # `conversion` is `-1` (none), `!r` (114), `!s` (115), or `!a` (97).
    # Apply BEFORE the format spec — Python evaluates `value!r:spec` as
    # `format(repr(value), spec)`. !r and !a both stringify via repr
    # (Pylixir's `py_repr` collapses both since we don't model ASCII
    # escaping distinctly).
    value_ast = apply_conversion(Map.get(node, "conversion", -1), value_ast)
    spec = extract_format_spec(Map.get(node, "format_spec"))

    case spec do
      :none ->
        {{:py_str, [], [value_ast]}, context}

      {:literal, text} ->
        {{:py_format_value, [], [value_ast, text]}, context}

      :unsupported ->
        raise UnsupportedNodeError,
          node_type: "FormattedValue",
          hint:
            "f-string format specs with nested interpolation aren't supported — use a constant spec like `:.2f` or `\"{:.2f}\".format(x)`",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  defp part(other, _context) do
    raise UnsupportedNodeError,
      node_type: "JoinedStr",
      hint:
        "unexpected JoinedStr child `#{Map.get(other, "_type")}` — expected Constant or FormattedValue"
  end

  # Format spec is itself a JoinedStr. If it's a single Constant string
  # (the common `:.2f` / `:02d` case), return its text; if it has
  # interpolations (`{width}`), fail.
  defp extract_format_spec(nil), do: :none
  defp extract_format_spec(%{"value" => nil}), do: :none

  defp extract_format_spec(%{"_type" => "JoinedStr", "values" => values}) do
    case values do
      [] -> :none
      [%{"_type" => "Constant", "value" => v}] when is_binary(v) -> {:literal, v}
      _ -> :unsupported
    end
  end

  defp extract_format_spec(m) when is_map(m) and map_size(m) == 0, do: :none
  defp extract_format_spec(_), do: :unsupported

  defp apply_conversion(-1, ast), do: ast
  defp apply_conversion(nil, ast), do: ast
  # !s — already what py_str does; wrap explicitly so spec sees a string.
  defp apply_conversion(115, ast), do: {:py_str, [], [ast]}
  # !r — repr; falls back to py_str for shapes py_repr doesn't special-case.
  defp apply_conversion(114, ast), do: {:py_repr, [], [ast]}
  # !a — Python's ascii(): repr + escape non-ASCII. Pylixir doesn't model
  # the escape distinction, so route through py_repr (same as !r).
  defp apply_conversion(97, ast), do: {:py_repr, [], [ast]}
end
