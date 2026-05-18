defmodule Pylixir.TypeInfer.Annotation do
  @moduledoc """
  Map a Python type-annotation AST node onto a Pylixir lattice type
  (`Pylixir.TypeInfer.t/0`).

  Only bare type names from Python's builtin set are recognised — the
  same set narrowed by `Pylixir.TypeInfer.IsinstanceNarrowing`. Anything
  else (subscripted generics like `List[int]`, dotted attribute names
  like `typing.List`, future-annotations strings, custom classes)
  collapses to `:any` so the inference layer can fall through to
  whatever it discovers from the body.

  Caller: `Pylixir.TypeInfer.Signatures.infer/3` — seeds
  `Context.fn_signatures` from each `FunctionDef`'s annotated param /
  return types before the fixed-point runs. Annotations are TRUSTED;
  no body-vs-annotation conflict check (mypy / pyright already own
  that lint).
  """

  @spec annotation_to_type(map() | nil) :: Pylixir.TypeInfer.t()
  def annotation_to_type(nil), do: :any
  def annotation_to_type(%{"_type" => "Name", "id" => "int"}), do: {:int}
  def annotation_to_type(%{"_type" => "Name", "id" => "float"}), do: {:float}
  def annotation_to_type(%{"_type" => "Name", "id" => "str"}), do: {:str}
  def annotation_to_type(%{"_type" => "Name", "id" => "bool"}), do: {:bool}
  def annotation_to_type(%{"_type" => "Name", "id" => "list"}), do: {:list, :any}
  def annotation_to_type(%{"_type" => "Name", "id" => "tuple"}), do: {:tuple, :any_arity}
  def annotation_to_type(%{"_type" => "Name", "id" => "dict"}), do: {:dict, :any, :any}
  def annotation_to_type(%{"_type" => "Name", "id" => "set"}), do: {:set}
  def annotation_to_type(%{"_type" => "Constant", "value" => nil}), do: {:none}
  def annotation_to_type(_), do: :any
end
