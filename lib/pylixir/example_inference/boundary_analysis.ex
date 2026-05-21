defmodule Pylixir.ExampleInference.BoundaryAnalysis do
  @moduledoc """
  Identify input-boundary assignment sites (Q4 C, docs/09). Tree-walks
  the module body and returns a map from `lineno → name` for every
  `Assign` whose RHS reaches `input(...)`, `sys.stdin.*`, or
  `sys.argv`.

  Only module-level top-level `Assign` statements with a single Name
  LHS are considered. Tuple/list LHS are skipped (per resolution: the
  type benefit lands via `bind_pattern → bind/3 → assume_types`; no
  guard is emitted for tuple destructuring).
  """

  @type t :: %{optional(non_neg_integer()) => String.t()}

  @doc """
  Scan a module body (list of statements). Returns a map keyed by the
  Assign statement's `lineno`, with the LHS Name id as the value.
  """
  @spec analyze([map()]) :: t()
  def analyze(body) when is_list(body) do
    Enum.reduce(body, %{}, fn stmt, acc ->
      case match_module_assign(stmt) do
        {lineno, name, rhs} ->
          if rhs_touches_input?(rhs), do: Map.put(acc, lineno, name), else: acc

        :no_match ->
          acc
      end
    end)
  end

  def analyze(_), do: %{}

  defp match_module_assign(%{
         "_type" => "Assign",
         "targets" => [%{"_type" => "Name", "id" => name}],
         "value" => rhs,
         "lineno" => lineno
       })
       when is_integer(lineno) do
    {lineno, name, rhs}
  end

  defp match_module_assign(_), do: :no_match

  defp rhs_touches_input?(node), do: deep_any?(node, &input_node?/1)

  defp deep_any?(%{} = node, pred) do
    cond do
      pred.(node) ->
        true

      true ->
        node
        |> Map.delete("_type")
        |> Enum.any?(fn {_k, v} -> deep_any?(v, pred) end)
    end
  end

  defp deep_any?(list, pred) when is_list(list), do: Enum.any?(list, &deep_any?(&1, pred))
  defp deep_any?(_other, _pred), do: false

  # `input(...)` call
  defp input_node?(%{"_type" => "Call", "func" => %{"_type" => "Name", "id" => "input"}}),
    do: true

  # `sys.stdin.<anything>` — Attribute(value=Attribute(value=Name(sys), attr=stdin), attr=...)
  defp input_node?(%{
         "_type" => "Attribute",
         "value" => %{
           "_type" => "Attribute",
           "value" => %{"_type" => "Name", "id" => "sys"},
           "attr" => "stdin"
         }
       }),
       do: true

  # `sys.argv`
  defp input_node?(%{
         "_type" => "Attribute",
         "value" => %{"_type" => "Name", "id" => "sys"},
         "attr" => "argv"
       }),
       do: true

  defp input_node?(_), do: false
end
