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
  @t26_conversions ~w(int float str bool list tuple set dict)
  @t26_type_checks ~w(isinstance)
  @t27_io_format ~w(print input chr ord hex oct bin round divmod any all)
  @supported MapSet.new(@t25a ++ @t25b ++ @t26_conversions ++ @t26_type_checks ++ @t27_io_format)

  @isinstance_map %{
    "int" => :integer,
    "float" => :float,
    "str" => :binary,
    "bool" => :boolean,
    "list" => :list,
    "tuple" => :tuple,
    "dict" => :map
  }

  @spec supported?(String.t()) :: boolean()
  def supported?(id), do: MapSet.member?(@supported, id)

  # Builtins with a clean single-arg `emit/3` clause. When a bare Python
  # reference to one of these (e.g. `map(int, xs)`) reaches the Name
  # converter, emit a unary lambda delegating to that clause rather than
  # falling through as an undefined Elixir variable. Variadic / kw-bearing
  # builtins (range, sorted, print, min, max, divmod, isinstance, ...)
  # are excluded — passing them as HOFs is unusual and the arity is
  # ambiguous without the call site.
  @unary_capturable ~w(int float str bool list tuple set dict abs len reversed
                       chr ord hex oct bin round)

  @spec unary_capturable?(String.t()) :: boolean()
  def unary_capturable?(id), do: id in @unary_capturable

  @spec unary_capture(String.t()) :: Macro.t()
  def unary_capture(id) do
    arg = {:x, [], nil}
    body = emit(id, [arg], %{})
    {:fn, [], [{:->, [], [[arg], body]}]}
  end

  @spec emit(String.t(), [Macro.t()], %{optional(String.t()) => Macro.t()}) :: Macro.t()
  def emit("len", [x], _kw), do: {:py_len, [], [x]}

  def emit("abs", [x], _kw), do: {:py_abs, [], [x]}

  def emit("range", [stop], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [], [{:.., [], [0, sub_one(stop)]}]}

  def emit("range", [start, stop], _kw),
    do:
      {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [], [{:.., [], [start, sub_one(stop)]}]}

  def emit("range", [start, stop, step], _kw),
    do:
      {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [],
       [{:..//, [], [start, sub_one(stop), step]}]}

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
    swap_fn =
      {:fn, [], [{:->, [], [[{{:x, [], nil}, {:i, [], nil}}], {{:i, [], nil}, {:x, [], nil}}]}]}

    {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [], [base, swap_fn]}
  end

  def emit("zip", [a, b], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [], [a, b]}

  def emit("zip", [a, b | rest], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [], [[a, b | rest]]}

  def emit("sum", [xs], _kw) do
    # Python sum() coerces booleans (RFC §6.11). Use py_add to retain that.
    reducer =
      {:fn, [],
       [
         {:->, [],
          [[{:a, [], nil}, {:b, [], nil}], {:py_add, [], [{:a, [], nil}, {:b, [], nil}]}]}
       ]}

    {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [xs, 0, reducer]}
  end

  def emit("min", [xs], kw), do: minmax_call(:min, xs, kw)
  def emit("max", [xs], kw), do: minmax_call(:max, xs, kw)
  def emit("min", [a, b | rest], _kw), do: minmax_variadic(:min, [a, b | rest])
  def emit("max", [a, b | rest], _kw), do: minmax_variadic(:max, [a, b | rest])

  def emit("map", [f, xs], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [], [xs, f]}

  def emit("filter", [f, xs], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :filter]}, [], [xs, f]}

  # --- T26 conversions ---------------------------------------------------

  def emit("int", [x], _kw), do: {:py_int, [], [x]}
  def emit("str", [x], _kw), do: {:py_str, [], [x]}
  def emit("bool", [x], _kw), do: {:truthy?, [], [x]}

  def emit("float", [x], _kw) do
    case x do
      v when is_binary(v) ->
        if String.downcase(String.trim(v)) in ~w(inf +inf -inf infinity +infinity -infinity nan) do
          raise ArgumentError,
                "Python `float(\"#{v}\")` is not supported (RFC §6.19 — Elixir has no inf/nan)"
        else
          {:py_float, [], [x]}
        end

      _ ->
        {:py_float, [], [x]}
    end
  end

  def emit("list", [x], _kw),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [], [x]}

  def emit("tuple", [x], _kw) do
    {{:., [], [{:__aliases__, [], [:List]}, :to_tuple]}, [],
     [{{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [], [x]}]}
  end

  def emit("set", [x], _kw),
    do: {{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], [x]}

  def emit("dict", [x], _kw),
    do: {{:., [], [{:__aliases__, [], [:Map]}, :new]}, [], [x]}

  # --- T26 type checks ---------------------------------------------------

  # isinstance(x, T) where T is a Name → guard call.
  def emit("isinstance", [_x, _type_ast] = [x, type_ast], _kw),
    do: isinstance_call(x, type_ast)

  # --- T27 IO + formatting ----------------------------------------------

  def emit("print", args, kw), do: emit_print(args, kw)

  def emit("input", [], _kw),
    do: {:py_input, [], [""]}

  def emit("input", [prompt], _kw),
    do: {:py_input, [], [prompt]}

  def emit("chr", [x], _kw),
    do: {{:., [], [{:__aliases__, [], [:List]}, :to_string]}, [], [[x]]}

  def emit("ord", [x], _kw) do
    charlist_call = {{:., [], [{:__aliases__, [], [:String]}, :to_charlist]}, [], [x]}
    {:hd, [], [charlist_call]}
  end

  def emit("hex", [x], _kw), do: {:py_hex, [], [x]}
  def emit("oct", [x], _kw), do: {:py_oct, [], [x]}
  def emit("bin", [x], _kw), do: {:py_bin, [], [x]}

  def emit("round", [x], _kw), do: {:py_round, [], [x]}
  def emit("round", [x, n], _kw), do: {:py_round, [], [x, n]}

  def emit("divmod", [a, b], _kw) do
    # Python: (a // b, a % b)
    fdiv = {:py_floor_div, [], [a, b]}
    mod = {:py_mod, [], [a, b]}
    {fdiv, mod}
  end

  def emit("any", [xs], _kw),
    do: enum_truthy_call(:any?, xs)

  def emit("all", [xs], _kw),
    do: enum_truthy_call(:all?, xs)

  def emit(name, _args, _kw),
    do:
      raise(ArgumentError, "Pylixir.Builtins.emit/3 has no clause for `#{name}` with these args")

  defp sub_one(ast) when is_integer(ast), do: ast - 1
  defp sub_one(ast), do: {:-, [], [ast, 1]}

  defp apply_sorted_kw(base, xs, kw) do
    base =
      case Map.get(kw, "key") do
        nil -> base
        f -> {{:., [], [{:__aliases__, [], [:Enum]}, :sort_by]}, [], [xs, f]}
      end

    case Map.get(kw, "reverse") do
      nil ->
        base

      true_ast when true_ast == true ->
        {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [base]}

      _other ->
        # Conservative: if `reverse=<expr>`, can't tell at codegen time.
        # Emit a conditional. For MVP, treat truthy as reverse.
        {:if, [],
         [
           {:truthy?, [], [Map.get(kw, "reverse")]},
           [do: {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [base]}, else: base]
         ]}
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

  # isinstance(x, T): the second arg is the converted AST of the type
  # reference. For a Python `int`, my T07 Name converter produces
  # `{:int, [], nil}` (or the Naming-rewritten form). We detect this
  # bare-name shape at codegen time.
  defp isinstance_call(x_ast, {type_atom, _meta, nil}) when is_atom(type_atom) do
    type_str = Atom.to_string(type_atom)

    case Map.get(@isinstance_map, type_str) do
      :integer ->
        # RFC §6.13: isinstance(True, int) == True in Python.
        {:||, [], [{:is_integer, [], [x_ast]}, {:is_boolean, [], [x_ast]}]}

      :float ->
        {:is_float, [], [x_ast]}

      :binary ->
        {:is_binary, [], [x_ast]}

      :boolean ->
        {:is_boolean, [], [x_ast]}

      :list ->
        {:is_list, [], [x_ast]}

      :tuple ->
        {:is_tuple, [], [x_ast]}

      :map ->
        {:&&, [], [{:is_map, [], [x_ast]}, {:!, [], [{:is_struct, [], [x_ast]}]}]}

      nil ->
        raise ArgumentError,
              "isinstance/2 with type `#{type_str}` is not supported; allowed: " <>
                inspect(Map.keys(@isinstance_map))
    end
  end

  defp isinstance_call(_x_ast, type_ast),
    do:
      raise(
        ArgumentError,
        "isinstance/2 second arg must be a bare type name; got #{inspect(type_ast, limit: 3)}"
      )

  defp enum_truthy_call(op, xs) do
    fn_ast = {:fn, [], [{:->, [], [[{:x, [], nil}], {:truthy?, [], [{:x, [], nil}]}]}]}
    {{:., [], [{:__aliases__, [], [:Enum]}, op]}, [], [xs, fn_ast]}
  end

  defp emit_print(args, kw) do
    sep_ast = Map.get(kw, "sep", " ")
    end_ast = Map.get(kw, "end", "\n")

    if Map.has_key?(kw, "file") do
      raise ArgumentError,
            "print(file=...) is not supported (RFC §6.7 — redirecting stdout requires IO.puts(device, ...))"
    end

    str_args =
      Enum.map(args, fn arg -> {:py_str, [], [arg]} end)

    joined =
      case str_args do
        [] ->
          ""

        [only] ->
          only

        _ ->
          {{:., [], [{:__aliases__, [], [:Enum]}, :join]}, [], [str_args, sep_ast]}
      end

    full =
      case end_ast do
        "" -> joined
        _ -> {:<>, [], [joined, end_ast]}
      end

    {{:., [], [{:__aliases__, [], [:IO]}, :write]}, [], [full]}
  end
end
