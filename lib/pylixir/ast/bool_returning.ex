defmodule Pylixir.AST.BoolReturning do
  @moduledoc """
  Predicate identifying Python AST nodes whose Elixir translation is
  guaranteed to be a boolean (`true` or `false`), so the surrounding
  `truthy?/1` wrap can be skipped.

  Currently `Compare` is the only safe case: `<`, `<=`, `==`, etc. all
  produce booleans in Elixir, and chained `Compare`s reduce to `&&`-folds
  of booleans. Everything else stays wrapped — including `BoolOp` (returns
  one of the operands, not a bool) and `Name` (unknown runtime type).

  False negatives (treating a bool-returning expression as non-bool) are
  merely verbose; false positives (treating a non-bool expression as
  bool) would silently miscompile Python's truthiness semantics.
  """

  @spec bool_returning?(map()) :: boolean()
  def bool_returning?(%{"_type" => "Compare"}), do: true
  def bool_returning?(_), do: false
end
