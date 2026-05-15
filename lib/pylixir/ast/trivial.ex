defmodule Pylixir.AST.Trivial do
  @moduledoc """
  Predicate identifying Python AST nodes that can be safely re-emitted at
  multiple call sites without observable difference from single
  evaluation.

  Used by single-evaluation rewrites in T12 (chained `Compare` middles),
  T13 (multi-target `Assign` RHS), and T14 (`AugAssign` subscript value
  and slice). When the predicate returns `false`, the surrounding rewrite
  binds the expression to a `py_tmp_<n>` once and references the temp
  thereafter.

  ## Trivial shapes

    * `Constant` — pure literal, no side effects.
    * `Name` — bare variable reference, no side effects.
    * `Attribute` whose `value` is recursively trivial — `obj.attr` reads
      have no side effects in Pylixir's supported Python subset (no
      descriptors / `__getattr__`).

  Everything else — `Call`, `BinOp`, `Compare`, `Subscript`, comprehensions,
  etc. — is considered non-trivial, so single-evaluation is enforced via
  temp binding even when the expression would in fact be pure. False
  negatives (treating a pure expression as non-trivial) are merely
  verbose; false positives (treating a side-effecting expression as
  trivial) would silently miscompile Python's single-evaluation
  semantics.
  """

  @spec trivial?(map() | any()) :: boolean()
  def trivial?(%{"_type" => "Constant"}), do: true
  def trivial?(%{"_type" => "Name"}), do: true
  def trivial?(%{"_type" => "Attribute", "value" => value}), do: trivial?(value)
  def trivial?(_), do: false
end
