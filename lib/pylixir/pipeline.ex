defmodule Pylixir.Pipeline do
  @moduledoc """
  Ordered list of module-top pre-passes that run before
  `Pylixir.Converter.convert/3` sees the `Module` node.

  ## Why this module exists

  Before this module, the pre-pass sequence was split across
  `Pylixir.to_source/2` (LiteralPropagation, ModuleAnalysis,
  ExampleInference) and the `Module` clause inside
  `Pylixir.Converter.convert/3` (module_summary,
  seed_module_attr_types, Signatures.infer). Discovering "what runs in
  what order" required reading two files. This module concentrates the
  list in one place.

  ## Shape

  `@passes` is a list of `{name, run_fn}` tuples. Each `run_fn` accepts
  a state map and returns an updated state map — heterogeneous
  signatures (each pass knows which keys it reads and writes). No
  uniform envelope, no god-Context. Adding a pass = one entry; pass
  dependencies are visible by inspection.

  State map keys:

    * `:body` — Python AST `body` list (modified by LiteralPropagation)
    * `:examples` — `[%{stdin, stdout}]` for ExampleInference
    * `:source` — original Python source string (or nil)
    * `:analysis` — `%Pylixir.ModuleAnalysis{}` (set by `:module_analysis`)
    * `:context` — `%Pylixir.Context{}` (set by `:context_init` onward)

  ## Scope decision

  Only true module-top pre-passes live here. The scoped passes
  `AlistAnalysis`, `PvecAnalysis`, `AppendBuildAnalysis` stay inline
  in `Converter.convert(Module)` — they configure context state for a
  specific conversion subsection (runtime statements vs function defs)
  and are intrinsic to how conversion is structured. Lifting them
  would leak conversion's scope semantics into Pipeline.

  Similarly, the `attr_names`/`class_names`/`class_methods` context
  setup at the head of `Converter.convert(Module)` stays inline
  because it depends on Converter-private helpers
  (`class_mutating_methods/1` et al.). The three TypeInfer pre-passes
  in this module (`module_summary`, `seed_module_attr_types`,
  `Signatures.infer`) verifiably do NOT read those fields, so the
  reorder is behaviour-preserving.

  ## Order constraint

  `GoldenCorpusTest` is semantic (stdout match), not syntactic. A
  reordering that preserves stdouts could still silently change
  generated Elixir source. The order below matches the pre-Pipeline
  execution sequence exactly:

    1. `:literal_propagation` — AST rewrite, runs first so analysis
       sees the propagated body.
    2. `:module_analysis` — produces the `%ModuleAnalysis{}` struct.
    3. `:context_init` — builds the initial `%Context{}` from analysis.
    4. `:example_seed` — `ExampleInference.seed/4` (encapsulates
       `BoundaryAnalysis.analyze/1` as a sub-pass).
    5. `:module_summary` — seeds `ctx.heap_types` for mutable module
       dicts.
    6. `:seed_module_attrs` — binds types for promoted module attrs.
    7. `:signatures` — bounded fixed-point function-signature inference.
  """

  alias Pylixir.{Context, ExampleInference, LiteralPropagation, ModuleAnalysis, TypeInfer}

  @type state :: %{
          required(:body) => [map()],
          required(:examples) => [map()],
          required(:source) => String.t() | nil,
          optional(:analysis) => ModuleAnalysis.t(),
          optional(:context) => Context.t()
        }

  @passes [
    {:literal_propagation, &__MODULE__.run_literal_propagation/1},
    {:module_analysis, &__MODULE__.run_module_analysis/1},
    {:context_init, &__MODULE__.run_context_init/1},
    {:example_seed, &__MODULE__.run_example_seed/1},
    {:module_summary, &__MODULE__.run_module_summary/1},
    {:seed_module_attrs, &__MODULE__.run_seed_module_attrs/1},
    {:signatures, &__MODULE__.run_signatures/1}
  ]

  @doc """
  Run all module-top pre-passes. Returns `%{body, context, analysis}`
  ready for `Pylixir.Converter.convert/3` to consume.

  `examples` may be `[]`; `source` may be `nil`.
  """
  @spec run([map()], [map()], String.t() | nil) :: %{
          body: [map()],
          context: Context.t(),
          analysis: ModuleAnalysis.t()
        }
  def run(body, examples, source) when is_list(body) and is_list(examples) do
    state = %{body: body, examples: examples, source: source}

    final = Enum.reduce(@passes, state, fn {_name, fun}, s -> fun.(s) end)

    %{body: final.body, context: final.context, analysis: final.analysis}
  end

  @doc """
  Return the ordered list of pass names — for introspection / docs.
  """
  @spec pass_names() :: [atom()]
  def pass_names, do: Enum.map(@passes, fn {name, _} -> name end)

  # ---------------------------------------------------------------------
  # Pass functions — each one declares which state keys it reads and
  # writes via its pattern match + return shape. Functions are public
  # only so the `@passes` list above can capture references at
  # compile-time; they are not part of Pylixir's public API.
  # ---------------------------------------------------------------------

  @doc false
  def run_literal_propagation(%{body: body} = state) do
    %{state | body: LiteralPropagation.rewrite(body)}
  end

  @doc false
  def run_module_analysis(%{body: body} = state) do
    Map.put(state, :analysis, ModuleAnalysis.analyze(body))
  end

  @doc false
  def run_context_init(%{analysis: analysis} = state) do
    context = %{
      Context.new(analysis.known_functions)
      | known_function_arities: analysis.known_function_arities,
        demoted_functions: analysis.demoted_function_names,
        mutable_module_dicts: analysis.mutable_module_dicts
    }

    Map.put(state, :context, context)
  end

  @doc false
  def run_example_seed(%{body: body, examples: examples, source: source, context: context} = state) do
    %{state | context: ExampleInference.seed(body, examples, context, source: source)}
  end

  @doc false
  def run_module_summary(%{analysis: analysis, context: context} = state) do
    %{state | context: TypeInfer.module_summary(analysis.runtime_statements, context)}
  end

  @doc false
  def run_seed_module_attrs(%{analysis: analysis, context: context} = state) do
    %{state | context: TypeInfer.seed_module_attr_types(analysis.module_attrs, context)}
  end

  @doc false
  def run_signatures(%{analysis: analysis, context: context} = state) do
    %{
      state
      | context:
          TypeInfer.Signatures.infer(analysis.function_defs, analysis.runtime_statements, context)
    }
  end
end
