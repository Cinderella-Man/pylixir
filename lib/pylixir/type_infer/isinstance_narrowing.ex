defmodule Pylixir.TypeInfer.IsinstanceNarrowing do
  @moduledoc """
  Recognize `isinstance(x, T)` and `isinstance(x, (T1, T2, …))` in
  if-test position and narrow `x`'s lattice type to the matched
  class(es) — PR 12 in the type-inference plan
  (`docs/02_type-inference-monomorphization.md` — decision Q12).

  Single public entry: `narrow/2`. Called from `Pylixir.Converter`'s
  `If` clause. If the test isn't an isinstance call (or the spec
  doesn't map to a concrete lattice type), returns the context
  unchanged.

  Soundness: narrowing only happens in the *true* branch. The false
  branch's complement isn't computed — Phase A scope per the design
  doc.

  Supported type-spec shapes:

    * Bare `Name("int" | "float" | "str" | "bool" | "list" | "dict" |
      "set" | "frozenset" | "tuple")` → the matching concrete lattice
      type.
    * `Tuple` of type specs → lub of the per-element lattice types
      (`isinstance(x, (int, str))` narrows `x` to `{:union, [{:int},
      {:str}]}`).
    * Anything else → `:any` (no narrowing).
  """

  alias Pylixir.{Context, TypeInfer}

  @doc """
  Apply isinstance-based narrowing to `context.types`. Returns the
  (possibly updated) context. Idempotent for non-isinstance tests.
  """
  @spec narrow(map(), Context.t()) :: Context.t()
  def narrow(
        %{
          "_type" => "Call",
          "func" => %{"_type" => "Name", "id" => "isinstance"},
          "args" => [%{"_type" => "Name", "id" => var_name}, type_spec]
        },
        context
      ) do
    case lattice_of_spec(type_spec) do
      :any -> context
      lattice -> TypeInfer.bind(context, var_name, lattice)
    end
  end

  def narrow(_test, context), do: context

  # Resolve the Python type-spec node to a lattice type.
  defp lattice_of_spec(%{"_type" => "Name", "id" => name}) do
    case name do
      "int" -> {:int}
      "float" -> {:float}
      "str" -> {:str}
      "bool" -> {:bool}
      "list" -> {:list, :any}
      "dict" -> {:dict, :any, :any}
      "set" -> {:set}
      "frozenset" -> {:set}
      "tuple" -> {:tuple, :any_arity}
      _ -> :any
    end
  end

  defp lattice_of_spec(%{"_type" => "Tuple", "elts" => elts}) do
    elts
    |> Enum.map(&lattice_of_spec/1)
    |> Enum.reduce(:bottom, fn t, acc -> TypeInfer.lub(acc, t) end)
    |> TypeInfer.demote_bottom()
  end

  defp lattice_of_spec(_), do: :any
end
