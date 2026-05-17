defmodule Pylixir.Context do
  @moduledoc """
  Conversion context threaded through `Pylixir.Converter.convert/2`. Every
  node clause receives a `Context` and returns the (potentially updated) one
  alongside the emitted Elixir AST — see the Conventions section in
  `docs/plan.md` for the contract.

  Fields (see RFC §10.2 plus later plan updates):

    * `:scopes` — stack of `MapSet`s tracking bound *Python* variable names
      per lexical scope. The head of the list is the innermost scope. T28's
      `Call` router consults this set FIRST when resolving a name.
    * `:while_counter` — monotonic counter used to name generated
      `while_<n>` helper functions (T18).
    * `:loop_nesting` — depth of nested loops; informs return-strategy
      decisions (T20).
    * `:known_functions` — `MapSet` of top-level function names collected in
      the pre-pass (RFC §10.3). Enables forward references.
    * `:temp_counter` — monotonic counter for single-evaluation temporaries
      (`py_tmp_<n>`) emitted in T12, T13, T14. Shared across all three so
      there is no name reuse anywhere in the same function.
    * `:module_attrs` — `MapSet` of Python names that have been promoted to
      Elixir module attributes (`@var_<name>`) by T05's mutation-scan pass.
      T07's `Name` converter emits `@var_<name>` for names in this set.
    * `:def_position` — `:module_top | :nested_fn | :other`. T19 reads this
      to decide whether to emit a `defp` (`:module_top`), defer to T21's
      anonymous-fn handling (`:nested_fn`), or raise (`:other` — function
      definitions inside control flow are not supported).
  """

  @type def_position :: :module_top | :nested_fn | :other

  @type return_mode :: nil | :unwrapped | :wrapped

  @type t :: %__MODULE__{
          scopes: [MapSet.t(String.t())],
          while_counter: non_neg_integer(),
          loop_nesting: non_neg_integer(),
          known_functions: MapSet.t(String.t()),
          temp_counter: non_neg_integer(),
          module_attrs: MapSet.t(String.t()),
          def_position: def_position(),
          loop_break_payload: nil | Macro.t(),
          while_helpers: [Macro.t()],
          return_mode: return_mode(),
          recursive_lambdas: MapSet.t(String.t()),
          recursive_self_binding: nil | String.t(),
          stdlib_aliases: %{optional(String.t()) => {String.t(), String.t()}}
        }

  @enforce_keys [:scopes]
  defstruct scopes: [],
            while_counter: 0,
            loop_nesting: 0,
            known_functions: MapSet.new(),
            temp_counter: 0,
            module_attrs: MapSet.new(),
            def_position: :module_top,
            loop_break_payload: nil,
            while_helpers: [],
            return_mode: nil,
            recursive_lambdas: MapSet.new(),
            recursive_self_binding: nil,
            stdlib_aliases: %{}

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
