defmodule Pylixir.ExampleInference.BoundaryGuard do
  @moduledoc """
  Emit runtime boundary-check guards for input-derived assignments
  (docs/09 step 6). Wraps the RHS expression in a `case` that raises
  `Pylixir.BoundaryViolationError` when the runtime value disagrees
  with the type observed during example-driven tracing.

  Scope (step 6 minimal): scalar types (`{:int}`, `{:float}`,
  `{:str}`, `{:bool}`) and `{:list, _}` (head-check). Other shapes
  (`{:dict, _, _}`, `{:tuple, _}`, `{:set}`, unions) fall through —
  the type info is still threaded via `assume_types`, but no runtime
  guard is emitted.
  """

  @doc """
  Returns `{:ok, wrapped_ast}` if the type is guardable, or `:skip`
  to fall through to the unwrapped emission.
  """
  @spec wrap(Macro.t(), String.t(), term()) :: {:ok, Macro.t()} | :skip
  def wrap(value_ast, name, type) when is_binary(name) do
    case guard_clauses(type, name) do
      {:ok, clauses} ->
        {:ok,
         {:case, [], [value_ast, [do: clauses]]}}

      :skip ->
        :skip
    end
  end

  defp guard_clauses({:int}, name), do: scalar_clauses(:is_integer, :int, name)
  defp guard_clauses({:float}, name), do: scalar_clauses(:is_float, :float, name)
  defp guard_clauses({:str}, name), do: scalar_clauses(:is_binary, :str, name)
  defp guard_clauses({:bool}, name), do: scalar_clauses(:is_boolean, :bool, name)

  defp guard_clauses({:list, elem_type}, name) do
    case scalar_guard(elem_type) do
      {:ok, guard_fn} ->
        clauses = [
          {:->, [],
           [
             [
               {:when, [],
                [
                  {:=, [], [{:|, [], [{:h, [], nil}, {:_, [], nil}]}, {:v, [], nil}]},
                  {guard_fn, [], [{:h, [], nil}]}
                ]}
             ],
             {:v, [], nil}
           ]},
          {:->, [], [[[]], []]},
          {:->, [],
           [
             [{:other, [], nil}],
             raise_call(name, {:list, elem_type})
           ]}
        ]

        {:ok, clauses}

      :skip ->
        :skip
    end
  end

  defp guard_clauses(_, _), do: :skip

  defp scalar_clauses(guard_fn, expected_atom, name) do
    clauses = [
      {:->, [],
       [
         [
           {:when, [],
            [
              {:v, [], nil},
              {guard_fn, [], [{:v, [], nil}]}
            ]}
         ],
         {:v, [], nil}
       ]},
      {:->, [],
       [
         [{:other, [], nil}],
         raise_call(name, expected_atom)
       ]}
    ]

    {:ok, clauses}
  end

  defp scalar_guard({:int}), do: {:ok, :is_integer}
  defp scalar_guard({:float}), do: {:ok, :is_float}
  defp scalar_guard({:str}), do: {:ok, :is_binary}
  defp scalar_guard({:bool}), do: {:ok, :is_boolean}
  defp scalar_guard(_), do: :skip

  defp raise_call(name, expected) do
    {:raise, [],
     [
       {:__aliases__, [alias: false], [:Pylixir, :BoundaryViolationError]},
       [
         name: name,
         expected: Macro.escape(expected),
         observed: {:other, [], nil}
       ]
     ]}
  end
end
