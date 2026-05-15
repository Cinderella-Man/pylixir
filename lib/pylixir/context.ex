defmodule Pylixir.Context do
  @moduledoc """
  Conversion context threaded through `Pylixir.Converter.convert/2`.

  Fields (see RFC §10.2):

    * `:scopes` — stack of `MapSet`s tracking bound variable names per lexical
      scope. The head of the list is the innermost scope.
    * `:while_counter` — monotonic counter used to name generated `while_<n>`
      helper functions.
    * `:loop_nesting` — depth of nested loops; informs return-strategy decisions
      (see RFC §10.6).
    * `:known_functions` — `MapSet` of top-level function names collected in the
      two-pass walk (RFC §10.3). Enables forward references.
  """

  @type t :: %__MODULE__{
          scopes: [MapSet.t(String.t())],
          while_counter: non_neg_integer(),
          loop_nesting: non_neg_integer(),
          known_functions: MapSet.t(String.t())
        }

  @enforce_keys [:scopes]
  defstruct scopes: [],
            while_counter: 0,
            loop_nesting: 0,
            known_functions: MapSet.new()

  @doc """
  Build a fresh context with a single empty scope and the given set of
  pre-collected function names.
  """
  @spec new(MapSet.t(String.t())) :: t()
  def new(known_functions \\ MapSet.new()) do
    %__MODULE__{
      scopes: [MapSet.new()],
      known_functions: known_functions
    }
  end
end
