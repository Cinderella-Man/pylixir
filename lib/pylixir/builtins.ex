defmodule Pylixir.Builtins do
  @moduledoc """
  Translation of Python built-in functions when called via
  `Call(func=Name(<id>), args=...)`. T25a covers iteration-shape
  primitives (`len`, `range`, `sorted`, `reversed`, `enumerate`, `zip`);
  T25b covers aggregation / functional (`sum`, `min`, `max`, `abs`,
  `map`, `filter`).

  `emit/3` returns a `Pylixir.Lowering.result()` — `{:ok, ast}` for a
  supported builtin call, `{:error, hint}` when the symbol is recognised
  but the specific shape is known-unsupported (e.g.
  `float("inf")`, `print(file=...)`), `:no_clause` when the name is in
  `@supported` but no clause matches the arg shape. `Pylixir.Converter`
  bridges the result to its `{ast, context}` contract through
  `Pylixir.Lowering.dispatch/4`.

  Builtins is deliberately *not* a `Pylixir.Stdlib` implementation —
  Python builtins live in the implicit global namespace, not under a
  module import. The two surfaces share the result type, not a
  behaviour.
  """

  @t25a ~w(len range sorted reversed enumerate zip)
  @t25b ~w(sum min max abs map filter)
  @t26_conversions ~w(int float str bool list tuple set frozenset dict)
  @t26_type_checks ~w(isinstance)
  @t27_io_format ~w(print input chr ord hex oct bin round divmod any all exit pow format repr iter next)
  # `bytearray(...)` — mutable bytes. Pylixir lowers to a plain list
  # of ints; subscript reads/writes and slice-assign work via the
  # existing list machinery. Behaves correctly for the sieve-of-
  # Eratosthenes idiom (bytearray([1]) * (n+1) + sieve[i*i::i] = b'\x00' * k).
  @t_bytes ~w(bytearray bytes)

  # `collections.deque` is technically not a builtin — it's imported
  # via `from collections import deque`. But the import is a no-op in
  # Pylixir (see Converter's ImportFrom clause), and bare `deque(…)`
  # calls land here. Backing rep is a plain Elixir list — `append`
  # already works via the mutation-method rewrite; `popleft` is
  # special-cased in `single_target_assign`.
  @t_collections ~w(deque Counter defaultdict)

  @supported MapSet.new(
               @t25a ++
                 @t25b ++
                 @t26_conversions ++
                 @t26_type_checks ++ @t27_io_format ++ @t_collections ++ @t_bytes
             )

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

  # Python builtins that Pylixir knows about but deliberately does NOT
  # lower. Without this set, a bare call like `iter(xs)` or `eval(s)`
  # would fall through the Converter's Name-call clause and become a
  # raw `iter(xs)` Elixir call — which then fails at compile time with
  # `undefined function iter/1` and surfaces as a generic
  # `compile_error--compile_quoted_raised` bucket with no actionable
  # hint. Catching them here turns the silent compile error into a
  # transpile-time `unsupported--Call` with a precise reason, so eval
  # buckets are informative.
  @unsupported %{
    "eval" => "`eval` (runtime code evaluation) is not supported",
    "exec" => "`exec` (runtime code evaluation) is not supported",
    "compile" => "`compile` (runtime code evaluation) is not supported",
    "getattr" => "dynamic attribute access (`getattr`) is not supported",
    "setattr" => "dynamic attribute mutation (`setattr`) is not supported",
    "hasattr" => "dynamic attribute access (`hasattr`) is not supported",
    "delattr" => "dynamic attribute deletion (`delattr`) is not supported",
    "vars" => "`vars` (introspection) is not supported",
    "locals" => "`locals` (introspection) is not supported",
    "globals" => "`globals` (introspection) is not supported",
    "dir" => "`dir` (introspection) is not supported",
    "id" => "`id` (object identity) is not supported",
    "hash" => "`hash` is not supported",
    "callable" => "`callable` is not supported",
    "super" => "`super` (classes are not supported)",
    # NOTE: `open` is deliberately not listed. The competitive-code
    # idiom `open(0).read()` reaches stdin via attribute_methods.ex's
    # receiver-discarding `.read()` clause — rejecting `open` here
    # would break that path. Real file I/O (e.g. `with open(p) as f`)
    # fails downstream in the With clause; that's the right layer.
    "slice" => "`slice` objects are not supported",
    "bytes" => "`bytes` is not supported",
    "bytearray" => "`bytearray` is not supported",
    "memoryview" => "`memoryview` is not supported",
    "complex" => "`complex` numbers are not supported",
    "issubclass" => "`issubclass` (classes are not supported)",
    "property" => "`property` (classes are not supported)",
    "classmethod" => "`classmethod` (classes are not supported)",
    "staticmethod" => "`staticmethod` (classes are not supported)",
    "object" => "`object` (classes are not supported)",
    "__import__" => "`__import__` (dynamic import) is not supported",
    "breakpoint" => "`breakpoint` is not supported",
    "help" => "`help` is not supported",
    "ascii" => "`ascii` is not supported",
    "aiter" => "async iteration is not supported",
    "anext" => "async iteration is not supported"
  }

  @spec unsupported_hint(String.t()) :: String.t() | nil
  def unsupported_hint(id), do: Map.get(@unsupported, id)

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
    # Every name in @unary_capturable has a one-arg `emit/3` clause that
    # returns {:ok, _} — the match is intentional.
    {:ok, body} = emit(id, [arg], %{})
    {:fn, [], [{:->, [], [[arg], body]}]}
  end

  alias Pylixir.TypeInfer

  @spec emit(String.t(), [Macro.t()], %{optional(String.t()) => Macro.t()}, [TypeInfer.t()]) ::
          Pylixir.Lowering.result()
  # PR 4 — type-aware specialization. When the arg type is concrete,
  # emit the matching kernel/stdlib call directly instead of the
  # polymorphic helper. Falls through to `emit/3` for everything else.

  def emit("len", [x], _kw, [t]) do
    cond do
      TypeInfer.is_list?(t) ->
        {:ok, {:length, [], [x]}}

      TypeInfer.is_str?(t) ->
        {:ok, {{:., [], [{:__aliases__, [], [:String]}, :length]}, [], [x]}}

      TypeInfer.is_dict?(t) ->
        {:ok, {:map_size, [], [x]}}

      TypeInfer.is_set?(t) ->
        {:ok, {{:., [], [{:__aliases__, [], [:MapSet]}, :size]}, [], [x]}}

      match?({:tuple, _}, t) ->
        {:ok, {:tuple_size, [], [x]}}

      true ->
        emit("len", [x], %{})
    end
  end

  # `int(int_value)` / `str(str_value)` / `bool(bool_value)` — Python
  # identity calls on already-typed values. Drop the wrapping helper
  # entirely.
  def emit("int", [x], kw, [t]) do
    if TypeInfer.is_int?(t), do: {:ok, x}, else: emit("int", [x], kw)
  end

  def emit("str", [x], kw, [t]) do
    if TypeInfer.is_str?(t), do: {:ok, x}, else: emit("str", [x], kw)
  end

  def emit("bool", [x], kw, [t]) do
    if t == {:bool}, do: {:ok, x}, else: emit("bool", [x], kw)
  end

  # PR 6 — drop `py_iter_to_list/1` wrap when the arg is statically a
  # list. The polymorphic helper is otherwise needed because Python
  # iterates strings/tuples/dicts/sets too. `TypeInfer.coerce_iter/2`
  # returns either the raw ast or the wrapped form.

  def emit("sorted", [xs], kw, [t]) do
    coerced = TypeInfer.coerce_iter(xs, t)
    base = {{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [coerced]}
    {:ok, apply_sorted_kw(base, coerced, kw)}
  end

  def emit("reversed", [xs], _kw, [t]) do
    {:ok, {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [TypeInfer.coerce_iter(xs, t)]}}
  end

  def emit("enumerate", [xs], kw, [t]) do
    enumerate_call(TypeInfer.coerce_iter(xs, t), Map.get(kw, "start"))
  end

  def emit("enumerate", [xs, start], _kw, [t, _]) do
    enumerate_call(TypeInfer.coerce_iter(xs, t), start)
  end

  def emit("zip", [a, b], _kw, [ta, tb]) do
    {:ok,
     {{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [],
      [TypeInfer.coerce_iter(a, ta), TypeInfer.coerce_iter(b, tb)]}}
  end

  def emit("zip", [a, b | rest], _kw, types) when length(types) == length([a, b | rest]) do
    args = Enum.zip([a, b | rest], types) |> Enum.map(fn {arg, t} -> TypeInfer.coerce_iter(arg, t) end)
    {:ok, {{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [], [args]}}
  end

  def emit("min", [xs], kw, [t]) do
    {:ok, minmax_call(:min, TypeInfer.coerce_iter(xs, t), kw)}
  end

  def emit("max", [xs], kw, [t]) do
    {:ok, minmax_call(:max, TypeInfer.coerce_iter(xs, t), kw)}
  end

  def emit("map", [f, xs], _kw, [_ft, t]) do
    {:ok,
     {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [], [TypeInfer.coerce_iter(xs, t), f]}}
  end

  def emit("filter", [f, xs], _kw, [_ft, t]) do
    {:ok,
     {{:., [], [{:__aliases__, [], [:Enum]}, :filter]}, [], [TypeInfer.coerce_iter(xs, t), f]}}
  end

  def emit("list", [x], _kw, [t]) do
    case t do
      {:list, _} -> {:ok, x}
      _ -> {:ok, {:py_iter_to_list, [], [x]}}
    end
  end

  def emit("set", [x], _kw, [t]) do
    {:ok,
     {{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], [TypeInfer.coerce_iter(x, t)]}}
  end

  def emit("frozenset", [x], _kw, [t]) do
    {:ok,
     {{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], [TypeInfer.coerce_iter(x, t)]}}
  end

  def emit("deque", [x], _kw, [t]) do
    case t do
      {:list, _} -> {:ok, x}
      _ -> {:ok, {:py_iter_to_list, [], [x]}}
    end
  end

  def emit("bytearray", [x], _kw, [t]) do
    case t do
      {:list, _} -> {:ok, x}
      _ -> {:ok, {:py_iter_to_list, [], [x]}}
    end
  end

  def emit("bytes", [x], _kw, [t]) do
    case t do
      {:list, _} -> {:ok, x}
      _ -> {:ok, {:py_iter_to_list, [], [x]}}
    end
  end

  def emit("tuple", [x], _kw, [t]) do
    {:ok,
     {{:., [], [{:__aliases__, [], [:List]}, :to_tuple]}, [], [TypeInfer.coerce_iter(x, t)]}}
  end

  def emit(id, args, kw, _arg_types), do: emit(id, args, kw)

  @spec emit(String.t(), [Macro.t()], %{optional(String.t()) => Macro.t()}) ::
          Pylixir.Lowering.result()
  def emit("len", [x], _kw), do: {:ok, {:py_len, [], [x]}}

  def emit("abs", [x], _kw), do: {:ok, {:py_abs, [], [x]}}

  # `range(stop)` and `range(start, stop)` — always ascending step 1.
  # Use the `//` explicit-step form so empty cases (`range(2, 2)`,
  # `range(0)`) produce `[]` instead of falling into Elixir's default
  # `a..b` step inference (which flips to `-1` when `a > b`).
  def emit("range", [stop], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [],
        [{:"..//", [], [0, sub_one(stop), 1]}]}}

  def emit("range", [start, stop], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [],
        [{:"..//", [], [start, sub_one(stop), 1]}]}}

  def emit("range", [start, stop, step], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:Enum]}, :to_list]}, [],
        [{:..//, [], [start, sub_one(stop), step]}]}}

  def emit("sorted", [xs], kw) do
    # Wrap in `py_iter_to_list/1` so Python iteration semantics apply:
    # `sorted(d)` returns sorted KEYS of the dict, not sorted entries.
    # No-op for lists; cheap.
    coerced = {:py_iter_to_list, [], [xs]}
    base = {{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [coerced]}
    {:ok, apply_sorted_kw(base, coerced, kw)}
  end

  # All iterator-consumers below wrap their iterable arg(s) in
  # `py_iter_to_list/1` so Python's "strings/tuples/dicts/sets are all
  # iterable" semantics holds. Otherwise `reversed("ab")` would emit
  # `Enum.reverse("ab")` and crash with `protocol Enumerable not
  # implemented for BitString` at runtime — a silent (transpiles-ok)
  # bug. No-op for lists.

  def emit("reversed", [xs], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [],
        [{:py_iter_to_list, [], [xs]}]}}

  def emit("enumerate", [xs], kw), do: enumerate_call(xs, Map.get(kw, "start"))
  def emit("enumerate", [xs, start], _kw), do: enumerate_call(xs, start)

  def emit("zip", [a, b], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [],
        [{:py_iter_to_list, [], [a]}, {:py_iter_to_list, [], [b]}]}}

  def emit("zip", [a, b | rest], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:Enum]}, :zip]}, [],
        [Enum.map([a, b | rest], &{:py_iter_to_list, [], [&1]})]}}

  def emit("sum", [xs], _kw), do: emit_sum(xs, 0)
  def emit("sum", [xs, start], _kw), do: emit_sum(xs, start)

  # `min(iter)` / `max(iter)` — wrap `iter` in py_iter_to_list so dict
  # → keys (matching Python's `min({"banana": 1, "apple": 2})` = "apple"
  # not the entry tuple). No-op for lists.
  def emit("min", [xs], kw),
    do: {:ok, minmax_call(:min, {:py_iter_to_list, [], [xs]}, kw)}

  def emit("max", [xs], kw),
    do: {:ok, minmax_call(:max, {:py_iter_to_list, [], [xs]}, kw)}
  def emit("min", [a, b | rest], _kw), do: {:ok, minmax_variadic(:min, [a, b | rest])}
  def emit("max", [a, b | rest], _kw), do: {:ok, minmax_variadic(:max, [a, b | rest])}

  # `map(f, xs)` / `filter(f, xs)` — wrap iterable in py_iter_to_list
  # so strings/tuples/dicts/sets all work; see the iter-consumers note
  # above `reversed`.
  def emit("map", [f, xs], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [],
        [{:py_iter_to_list, [], [xs]}, f]}}

  def emit("filter", [f, xs], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:Enum]}, :filter]}, [],
        [{:py_iter_to_list, [], [xs]}, f]}}

  # --- T26 conversions ---------------------------------------------------

  # Python's `int()` / `str()` / `bool()` / `float()` / `list()` /
  # `tuple()` / `set()` / `dict()` with no args all return the
  # "empty/zero value" of their respective type. Pylixir handles them
  # at codegen time as their corresponding Elixir literals.
  def emit("int", [], _kw), do: {:ok, 0}
  def emit("int", [x], _kw), do: {:ok, {:py_int, [], [x]}}

  # `int(string, base)` — Python's base-aware parse. Lowers to
  # `String.to_integer/2`, which is the matching Elixir BIF.
  def emit("int", [x, base], _kw),
    do: {:ok, {{:., [], [{:__aliases__, [], [:String]}, :to_integer]}, [], [x, base]}}

  def emit("str", [], _kw), do: {:ok, ""}
  def emit("str", [x], _kw), do: {:ok, {:py_str, [], [x]}}

  def emit("bool", [], _kw), do: {:ok, false}
  def emit("bool", [x], _kw), do: {:ok, {:truthy?, [], [x]}}

  def emit("float", [], _kw), do: {:ok, 0.0}

  # Elixir floats can't represent IEEE +/- infinity natively, but the
  # idiomatic Python use of `float('inf')` is as a comparison sentinel
  # in min/max-finding loops — for which a very-large-magnitude float
  # is observationally equivalent. We emit `1.0e308` (positive) /
  # `-1.0e308` (negative): bigger than any practical finite value, so
  # `x < pos_inf` holds for every finite `x`. Fidelity loss is in IEEE
  # corner cases — `inf - inf` becomes `0.0` instead of NaN, `inf * 2`
  # overflows instead of saturating — none of which appear in
  # algorithmic Python idioms. NaN itself stays unsupported (no good
  # Elixir representation).
  def emit("float", [x], _kw) do
    case x do
      v when is_binary(v) ->
        case classify_float_literal(v) do
          :positive_infinity ->
            {:ok, 1.0e308}

          :negative_infinity ->
            {:ok, -1.0e308}

          :nan ->
            {:error, "Python `float(\"#{v}\")` (NaN) is not supported (Elixir has no IEEE NaN)"}

          :finite ->
            {:ok, {:py_float, [], [x]}}
        end

      _ ->
        {:ok, {:py_float, [], [x]}}
    end
  end

  def emit("list", [], _kw), do: {:ok, []}

  # `list(iter)` — route through `py_iter_to_list/1` so tuples (which
  # Elixir doesn't treat as Enumerable) and strings (Python iterates
  # grapheme-by-grapheme) work alongside lists/ranges/maps. Earlier
  # `Enum.to_list/1` crashed on tuple inputs with
  # `Protocol.UndefinedError`.
  def emit("list", [x], _kw),
    do: {:ok, {:py_iter_to_list, [], [x]}}

  def emit("tuple", [], _kw), do: {:ok, {:{}, [], []}}

  def emit("tuple", [x], _kw) do
    {:ok,
     {{:., [], [{:__aliases__, [], [:List]}, :to_tuple]}, [],
      [{:py_iter_to_list, [], [x]}]}}
  end

  def emit("set", [], _kw),
    do: {:ok, {{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], []}}

  def emit("set", [x], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], [{:py_iter_to_list, [], [x]}]}}

  # `frozenset()` / `frozenset(iter)` — Elixir has no separate frozen vs
  # mutable set; MapSet already has value semantics + immutability. Both
  # forms lower to the same MapSet shape as `set(...)`. `py_str` reports
  # them as `set(...)` — known minor cosmetic divergence; tests that
  # only assert membership/equality (the common case in eval samples)
  # are unaffected.
  def emit("frozenset", [], _kw),
    do: {:ok, {{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], []}}

  def emit("frozenset", [x], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:MapSet]}, :new]}, [], [{:py_iter_to_list, [], [x]}]}}

  def emit("dict", [], _kw), do: {:ok, {:%{}, [], []}}

  def emit("dict", [x], _kw),
    do: {:ok, {{:., [], [{:__aliases__, [], [:Map]}, :new]}, [], [x]}}

  # `deque()` / `deque(iter)` — backing rep is a plain Elixir list.
  # `py_iter_to_list/1` keeps string/tuple/dict args working (`Enum.to_list`
  # alone crashes on tuples).
  def emit("deque", [], _kw), do: {:ok, []}

  def emit("deque", [x], _kw),
    do: {:ok, {:py_iter_to_list, [], [x]}}

  # `bytearray()` / `bytearray(iter)` / `bytes(iter)` — mutable
  # (immutable for `bytes`) sequence of unsigned 8-bit ints. Pylixir
  # backing is a plain list of ints; subscript reads/writes and
  # slice-assign already work over lists. Bytes literals (`b'\x00'`)
  # arrive as Python `Constant` nodes with a `bytes`-typed value,
  # which serialise into list-of-int form via `serialize.py`.
  def emit("bytearray", [], _kw), do: {:ok, []}
  def emit("bytearray", [x], _kw), do: {:ok, {:py_iter_to_list, [], [x]}}
  def emit("bytes", [], _kw), do: {:ok, []}
  def emit("bytes", [x], _kw), do: {:ok, {:py_iter_to_list, [], [x]}}

  # `Counter(iter)` → dict-of-counts. Elixir's `Enum.frequencies/1` is
  # the exact equivalent. (Counter's other features — most_common,
  # arithmetic — aren't supported yet; standard `.get`/`.items` work
  # since the result IS a plain map.)
  def emit("Counter", [], _kw), do: {:ok, {:%{}, [], []}}

  def emit("Counter", [x], _kw),
    do:
      {:ok,
       {{:., [], [{:__aliases__, [], [:Enum]}, :frequencies]}, [],
        [{:py_iter_to_list, [], [x]}]}}

  # `defaultdict(factory)` — Elixir doesn't track the factory, so we
  # emit a plain `%{}` and rely on `py_getitem` returning `nil` for
  # missing keys + `py_add(nil, x)` treating `nil` as 0. Works for
  # `d[k] += 1` (the dominant idiom). For factory=list, the user must
  # use `d.get(k, [])` since `py_add(nil, list)` doesn't infer the
  # empty-list identity.
  def emit("defaultdict", [_factory], _kw), do: {:ok, {:%{}, [], []}}
  def emit("defaultdict", [], _kw), do: {:ok, {:%{}, [], []}}

  # --- T26 type checks ---------------------------------------------------

  # isinstance(x, T) where T is a Name → guard call.
  def emit("isinstance", [x, type_ast], _kw), do: isinstance_call(x, type_ast)

  # --- T27 IO + formatting ----------------------------------------------

  def emit("print", args, kw), do: emit_print(args, kw)

  def emit("input", [], _kw), do: {:ok, {:py_input, [], [""]}}

  def emit("input", [prompt], _kw), do: {:ok, {:py_input, [], [prompt]}}

  def emit("chr", [x], _kw),
    do: {:ok, {{:., [], [{:__aliases__, [], [:List]}, :to_string]}, [], [[x]]}}

  def emit("ord", [x], _kw) do
    charlist_call = {{:., [], [{:__aliases__, [], [:String]}, :to_charlist]}, [], [x]}
    {:ok, {:hd, [], [charlist_call]}}
  end

  def emit("hex", [x], _kw), do: {:ok, {:py_hex, [], [x]}}
  def emit("oct", [x], _kw), do: {:ok, {:py_oct, [], [x]}}
  def emit("bin", [x], _kw), do: {:ok, {:py_bin, [], [x]}}

  def emit("round", [x], _kw), do: {:ok, {:py_round, [], [x]}}
  def emit("round", [x, n], _kw), do: {:ok, {:py_round, [], [x, n]}}

  def emit("divmod", [a, b], _kw) do
    # Python: (a // b, a % b)
    fdiv = {:py_floor_div, [], [a, b]}
    mod = {:py_mod, [], [a, b]}
    {:ok, {fdiv, mod}}
  end

  # Python's `pow(base, exp)` — same as `base ** exp` (delegates to py_pow).
  # Python's `pow(base, exp, mod)` — modular exponentiation, common in
  # competitive code for Fermat-based modular inverses.
  def emit("pow", [base, exp], _kw), do: {:ok, {:py_pow, [], [base, exp]}}
  def emit("pow", [base, exp, mod], _kw), do: {:ok, {:py_pow_mod, [], [base, exp, mod]}}

  def emit("any", [xs], _kw), do: {:ok, enum_truthy_call(:any?, xs)}
  def emit("all", [xs], _kw), do: {:ok, enum_truthy_call(:all?, xs)}

  # Python's builtin `repr(value)` — already implemented as
  # `py_repr/1` for str/list/tuple/dict containers (used by f-string
  # `!r` and the existing py_repr_* helpers). The standalone builtin
  # just calls the same helper.
  def emit("repr", [v], _kw), do: {:ok, {:py_repr, [], [v]}}

  # Python's builtin `format(value[, spec])` — same surface as
  # `"{:spec}".format(value)` but on a single value. With no spec it's
  # `str(value)`; with a spec it routes through the shared
  # `py_format_value/2` parser. The .format() path in
  # `Pylixir.Nodes.AttributeMethods` already does this — reuse here so
  # both lowering paths converge on one runtime.
  def emit("format", [value], _kw), do: {:ok, {:py_str, [], [value]}}
  def emit("format", [value, spec], _kw), do: {:ok, {:py_format_value, [], [value, spec]}}

  # `exit()` / `exit(code)` throw via `Pylixir.ControlFlow.throw_exit/1`;
  # py_main's try/catch wrapper (see `Pylixir.Converter.py_main_def/1`)
  # catches the throw and returns the code so the BEAM survives —
  # `System.halt` would kill the test VM during the golden-corpus run.
  # `iter(x)` and `next(it)` — partial iterator protocol. `iter(x)`
  # wraps the iterable in a process-dict-backed cursor (returns an
  # integer handle); subsequent `c in it`-style checks dispatch to
  # the iterator-aware `py_in` clause and advance the cursor; bare
  # `next(it)` pops the head element. The shortcut `next(iter(x))`
  # is intercepted earlier (Converter.detect_next_iter) and lowered
  # without going through the cursor — same observable behaviour,
  # cheaper.
  def emit("iter", [x], _kw), do: {:ok, {:py_iter_make, [], [x]}}

  def emit("next", [it], _kw), do: {:ok, {:py_iter_next, [], [it]}}

  def emit("next", [it, default], _kw), do: {:ok, {:py_iter_next, [], [it, default]}}

  def emit("exit", [], _kw), do: {:ok, Pylixir.ControlFlow.throw_exit(0)}

  def emit("exit", [code], _kw), do: {:ok, Pylixir.ControlFlow.throw_exit(code)}

  # Catch-all: name was in @supported (so the caller routed here) but no
  # clause matched the arg shape. The caller (`Lowering.dispatch/4`)
  # builds the user-facing hint.
  def emit(_name, _args, _kw), do: :no_clause

  defp sub_one(ast) when is_integer(ast), do: ast - 1
  defp sub_one(ast), do: {:-, [], [ast, 1]}

  defp emit_sum(xs, start) do
    # Python sum() coerces booleans (RFC §6.11). Use py_add to retain that.
    # Reducer takes (elem, acc) — pass acc first to py_add so list concat
    # (`sum([[1,2],[3,4]], [])`) preserves source order: acc ++ elem.
    reducer =
      {:fn, [],
       [
         {:->, [],
          [[{:elem, [], nil}, {:acc, [], nil}], {:py_add, [], [{:acc, [], nil}, {:elem, [], nil}]}]}
       ]}

    coerced = {:py_iter_to_list, [], [xs]}
    {:ok, {{:., [], [{:__aliases__, [], [:Enum]}, :reduce]}, [], [coerced, start, reducer]}}
  end

  defp classify_float_literal(v) do
    case String.downcase(String.trim(v)) do
      s when s in ~w(inf +inf infinity +infinity) -> :positive_infinity
      s when s in ~w(-inf -infinity) -> :negative_infinity
      "nan" -> :nan
      _ -> :finite
    end
  end

  defp apply_sorted_kw(base, xs, kw) do
    key = Map.get(kw, "key")
    reverse = Map.get(kw, "reverse")

    # Python's `sorted(reverse=True)` is a STABLE descending sort —
    # equal-key elements keep their original order. Composing a stable
    # ascending sort with `Enum.reverse` flips that, breaking
    # stability. Use Enum.sort/sort_by with `:desc` instead so the
    # comparator itself runs in descending mode, preserving stability.
    desc? = reverse == true

    case {key, desc?} do
      {nil, false} -> base
      {nil, true} -> {{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [xs, :desc]}
      # Route key-bearing sorts through `py_sorted_by` so the runtime
      # can pattern-match a `{:py_cmp_to_key, cmp}` shape (Python's
      # `functools.cmp_to_key` wraps a comparator into a key) and use
      # `Enum.sort` with the comparator instead of `Enum.sort_by`.
      # Plain key fns fall through to `Enum.sort_by` as before.
      {f, false} -> {:py_sorted_by, [], [xs, f]}
      {f, true} -> {:py_sorted_by_desc, [], [xs, f]}
    end
    |> maybe_runtime_reverse(reverse, key, xs)
  end

  # Fallback: when `reverse=` is a non-literal expression we can't
  # decide at codegen time. Stability won't be quite right (uses
  # Enum.reverse on a stable ascending sort), but the alternative is
  # generating a runtime branch on `:desc` which Enum can't accept as
  # a dynamic value. Rare in practice — every eval-corpus usage is
  # literal True or False.
  defp maybe_runtime_reverse(base, true, _key, _xs), do: base
  defp maybe_runtime_reverse(base, false, _key, _xs), do: base
  defp maybe_runtime_reverse(base, nil, _key, _xs), do: base

  defp maybe_runtime_reverse(_base, reverse_ast, key, xs) do
    ascending =
      case key do
        nil -> {{:., [], [{:__aliases__, [], [:Enum]}, :sort]}, [], [xs]}
        f -> {:py_sorted_by, [], [xs, f]}
      end

    {:if, [],
     [
       {:truthy?, [], [reverse_ast]},
       [do: {{:., [], [{:__aliases__, [], [:Enum]}, :reverse]}, [], [ascending]}, else: ascending]
     ]}
  end

  # Shared by `enumerate(xs)` / `enumerate(xs, start=N)` / `enumerate(xs, N)`.
  # Lowers to `Enum.with_index/1` or `/2` and post-maps {x, i} → {i, x}
  # to match Python's tuple order.
  defp enumerate_call(xs, start) do
    coerced = {:py_iter_to_list, [], [xs]}

    base =
      if start do
        {{:., [], [{:__aliases__, [], [:Enum]}, :with_index]}, [], [coerced, start]}
      else
        {{:., [], [{:__aliases__, [], [:Enum]}, :with_index]}, [], [coerced]}
      end

    swap_fn =
      {:fn, [], [{:->, [], [[{{:x, [], nil}, {:i, [], nil}}], {{:i, [], nil}, {:x, [], nil}}]}]}

    {:ok, {{:., [], [{:__aliases__, [], [:Enum]}, :map]}, [], [base, swap_fn]}}
  end

  defp minmax_call(op, xs, kw) do
    key = Map.get(kw, "key")
    default = Map.get(kw, "default")

    case {key, default} do
      {nil, nil} ->
        {{:., [], [{:__aliases__, [], [:Enum]}, op]}, [], [xs]}

      {nil, default_ast} ->
        {{:., [], [{:__aliases__, [], [:Enum]}, op]}, [],
         [xs, {:fn, [], [{:->, [], [[], default_ast]}]}]}

      {key_ast, nil} ->
        # Python's `min(xs, key=fn)` — pick the element with smallest
        # `fn(x)`. Enum has `min_by`/`max_by` that do exactly this.
        by_op = if op == :min, do: :min_by, else: :max_by
        {{:., [], [{:__aliases__, [], [:Enum]}, by_op]}, [], [xs, key_ast]}

      {key_ast, default_ast} ->
        # Both key= and default= — Enum.min_by/4 accepts a sorter
        # (default `&<=/2`) and an empty_fallback 0-arity fn. Pass the
        # default through the fallback so empty iterables match Python.
        by_op = if op == :min, do: :min_by, else: :max_by
        sorter =
          {:fn, [],
           [
             {:->, [],
              [[{:a, [], nil}, {:b, [], nil}], {:<=, [], [{:a, [], nil}, {:b, [], nil}]}]}
           ]}
        fallback = {:fn, [], [{:->, [], [[], default_ast]}]}
        {{:., [], [{:__aliases__, [], [:Enum]}, by_op]}, [],
         [xs, key_ast, sorter, fallback]}
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
        {:ok, {:||, [], [{:is_integer, [], [x_ast]}, {:is_boolean, [], [x_ast]}]}}

      :float ->
        {:ok, {:is_float, [], [x_ast]}}

      :binary ->
        {:ok, {:is_binary, [], [x_ast]}}

      :boolean ->
        {:ok, {:is_boolean, [], [x_ast]}}

      :list ->
        {:ok, {:is_list, [], [x_ast]}}

      :tuple ->
        {:ok, {:is_tuple, [], [x_ast]}}

      :map ->
        {:ok, {:&&, [], [{:is_map, [], [x_ast]}, {:!, [], [{:is_struct, [], [x_ast]}]}]}}

      nil ->
        {:error,
         "isinstance/2 with type `#{type_str}` is not supported; allowed: " <>
           inspect(Map.keys(@isinstance_map))}
    end
  end

  defp isinstance_call(_x_ast, type_ast),
    do:
      {:error,
       "isinstance/2 second arg must be a bare type name; got #{inspect(type_ast, limit: 3)}"}

  defp enum_truthy_call(op, xs) do
    fn_ast = {:fn, [], [{:->, [], [[{:x, [], nil}], {:truthy?, [], [{:x, [], nil}]}]}]}
    coerced = {:py_iter_to_list, [], [xs]}
    {{:., [], [{:__aliases__, [], [:Enum]}, op]}, [], [coerced, fn_ast]}
  end

  defp emit_print(args, kw) do
    if Map.has_key?(kw, "file") do
      {:error,
       "print(file=...) is not supported (RFC §6.7 — redirecting stdout requires IO.puts(device, ...))"}
    else
      sep_ast = Map.get(kw, "sep", " ")
      end_ast = Map.get(kw, "end", "\n")

      str_args = Enum.map(args, fn arg -> {:py_str, [], [arg]} end)

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

      {:ok, {{:., [], [{:__aliases__, [], [:IO]}, :write]}, [], [full]}}
    end
  end
end
