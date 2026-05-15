defmodule Pylixir.Builtins do
  @moduledoc """
  Translation of Python built-in functions when called via
  `Call(func=Name(<id>), args=...)`. T25a covers iteration-shape
  primitives (`len`, `range`, `sorted`, `reversed`, `enumerate`, `zip`);
  T25b covers aggregation / functional (`sum`, `min`, `max`, `abs`,
  `map`, `filter`).

  T28's router will eventually own the dispatch precedence
  (local-scope shadow → known module-fn → builtin → unsupported builtin).
  Until then, the minimal `Call` clause in `Pylixir.Converter` consults
  `supported?/1` and delegates to `emit/3`.
  """

  @t25a ~w(len range sorted reversed enumerate zip)
  @t25b ~w(sum min max abs map filter)
  @supported MapSet.new(@t25a ++ @t25b)

  @spec supported?(String.t()) :: boolean()
  def supported?(id), do: MapSet.member?(@supported, id)

  @spec emit(String.t(), [Macro.t()], %{optional(String.t()) => Macro.t()}) :: Macro.t()
  def emit("len", [x], _kw), do: {:py_len, [], [x]}

  def emit("abs", [x], _kw), do: {:py_abs, [], [x]}

  def emit("range", [stop], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [], [{:.., [], [0, sub_one(stop)]}]}

  def emit("range", [start, stop], _kw),
    do:
      {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [],
       [{:.., [], [start, sub_one(stop)]}]}

  def emit("range", [start, stop, step], _kw),
    do:
      {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [],
       [{:"..//", [], [start, sub_one(stop), step]}]}

  def emit("sorted", [xs], kw) do
    base = {{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [xs]}
    apply_sorted_kw(base, xs, kw)
  end

  def emit("reversed", [xs], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [xs]}

  def emit("enumerate", [xs], kw) do
    start =
      case Map.get(kw, "start") do
        nil -> nil
        ast -> ast
      end

    base =
      if start do
        {{:., [], [{:__aliases__, [], [:Enum]}, :with_index]}, [], [xs, start]}
      else
        {{:., [], [{:__aliases__, [], [:Enum]}, :with_index]}, [], [xs]}
      end

    # Python yields (i, x); Elixir yields {x, i}. Swap via Enum.map.
    swap_fn = {:fn, [], [{:->, [], [[{{:x, [], nil}, {:i, [], nil}}], {{:i, [], nil}, {:x, [], nil}}]}]}
    {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [], [base, swap_fn]}
  end

  def emit("zip", [a, b], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [], [a, b]}

  def emit("zip", [a, b | rest], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [], [[a, b | rest]]}

  def emit("sum", [xs], _kw), do: {{:., [], [{:__aliases__, [], [:Enum]}, :sum]}, [], [xs]}

  def emit("min", [xs], kw), do: minmax_call(:min, xs, kw)
  def emit("max", [xs], kw), do: minmax_call(:max, xs, kw)
  def emit("min", [a, b | rest], _kw), do: minmax_variadic(:min, [a, b | rest])
  def emit("max", [a, b | rest], _kw), do: minmax_variadic(:max, [a, b | rest])

  def emit("map", [f, xs], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [], [xs, f]}

  def emit("filter", [f, xs], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :filter]}, [], [xs, f]}

  def emit(name, _args, _kw),
    do: raise(ArgumentError, "Pylixir.Builtins.emit/3 has no clause for `#{name}` with these args")

  defp sub_one(ast) when is_integer(ast), do: ast - 1
  defp sub_one(ast), do: {:-, [], [ast, 1]}

  defp apply_sorted_kw(base, xs, kw) do
    base =
      case Map.get(kw, "key") do
        nil -> base
        f -> {{:., [], [{:__aliases__, [], [:Enum]}, :sort_by]}, [], [xs, f]}
      end

    case Map.get(kw, "reverse") do
      nil -> base
      true_ast when true_ast == true -> {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [base]}
      _other ->
        # Conservative: if `reverse=<expr>`, can't tell at codegen time.
        # Emit a conditional. For MVP, treat truthy as reverse.
        {:if, [], [{:truthy?, [], [Map.get(kw, "reverse")]},
                  [do: {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [base]}, else: base]]}
    end
  end

  defp minmax_call(op, xs, kw) do
    case Map.get(kw, "default") do
      nil ->
        {{:., [], [{:__aliases__, [], [:Enum]}, op]}, [], [xs]}

      default_ast ->
        {{:., [], [{:__aliases__, [], [:Enum]}, op]}, [],
         [xs, {:fn, [], [{:->, [], [[], default_ast]}]}]}
    end
  end

  defp minmax_variadic(op, args) do
    {{:., [], [{:__aliases__, [], [:Enum]}, op]}, [], [args]}
  end
end
