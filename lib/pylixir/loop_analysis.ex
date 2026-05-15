defmodule Pylixir.LoopAnalysis do
  @moduledoc """
  Static analysis of a loop body (Python `For.body` or `While.body`)
  determining which Python names get assigned somewhere inside it.

  T16b uses the result to choose between `Enum.each` (no assigned vars
  — pure side-effect loop) and `Enum.reduce` (1+ assigned vars need
  accumulator threading). T18's `While` codegen consumes the same
  result.

  ## Over-thread policy

  Any name that appears as the *target* of one of the following is
  collected — even if the assignment is inside a nested `If`/`For`/
  `While` branch and may only fire on some paths:

    * `Assign` — direct rebinding (including tuple-unpack targets,
      which mention every name they bind).
    * `AugAssign` — `x += 1` (the root name, including subscript /
      attribute roots: `lst[i] += 1` rebinds `lst` per T14's
      `py_setitem` rewrite).
    * `For` target — the loop variable.

  ## Scope barriers

  The walk uses `Pylixir.AST.Walk.walk_scope/3`, which stops at
  `FunctionDef`/`Lambda`/`ClassDef`/comprehension boundaries — those
  have their own scope in Python, so a `def inner(): x = 5` inside the
  loop body does NOT add `x` to the outer assigned_vars.
  """

  alias Pylixir.AST.Walk

  @type t :: %__MODULE__{
          assigned_vars: MapSet.t(String.t()),
          referenced_vars: MapSet.t(String.t())
        }

  defstruct assigned_vars: MapSet.new(), referenced_vars: MapSet.new()

  @doc """
  Analyse the body of a `For` or `While` loop. Returns a
  `%Pylixir.LoopAnalysis{}` carrying:

    * `:assigned_vars` — names assigned anywhere in the body
      (boundary-respecting).
    * `:referenced_vars` — names *read* anywhere in the body. T18's
      While codegen subtracts the assigned set from this to determine
      read-only outer-scope variables that must be passed through the
      recursive helper.
  """
  @spec analyze([map()]) :: t()
  def analyze(body) when is_list(body) do
    {assigned, referenced} =
      Enum.reduce(body, {MapSet.new(), MapSet.new()}, fn node, {a_acc, r_acc} ->
        Walk.walk_scope(node, {a_acc, r_acc}, fn n, {a, r} ->
          {MapSet.union(a, names_assigned_in(n)),
           MapSet.union(r, names_referenced_in(n))}
        end)
      end)

    %__MODULE__{assigned_vars: assigned, referenced_vars: referenced}
  end

  defp names_referenced_in(%{"_type" => "Name", "id" => id}), do: MapSet.new([id])
  defp names_referenced_in(_), do: MapSet.new()

  defp names_assigned_in(%{"_type" => "Assign", "targets" => targets}) do
    targets |> Enum.flat_map(&target_names/1) |> MapSet.new()
  end

  defp names_assigned_in(%{"_type" => "AugAssign", "target" => target}) do
    target |> target_names() |> MapSet.new()
  end

  defp names_assigned_in(%{"_type" => "For", "target" => target}) do
    target |> target_names() |> MapSet.new()
  end

  defp names_assigned_in(_), do: MapSet.new()

  defp target_names(%{"_type" => "Name", "id" => id}), do: [id]

  defp target_names(%{"_type" => "Tuple", "elts" => elts}),
    do: Enum.flat_map(elts, &target_names/1)

  defp target_names(%{"_type" => "Subscript", "value" => value}),
    do: List.wrap(root_name(value))

  defp target_names(%{"_type" => "Attribute", "value" => value}),
    do: List.wrap(root_name(value))

  defp target_names(_), do: []

  defp root_name(%{"_type" => "Name", "id" => id}), do: id
  defp root_name(%{"_type" => "Subscript", "value" => v}), do: root_name(v)
  defp root_name(%{"_type" => "Attribute", "value" => v}), do: root_name(v)
  defp root_name(_), do: nil
end
