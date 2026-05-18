defmodule Pylixir.Stdlib.Math do
  @moduledoc """
  Pylixir.Stdlib implementation for Python's `math` module. Translates
  attribute references (`math.pi`) and method calls (`math.sqrt(x)`) to
  Erlang's `:math` BIFs. Previously inlined into `Pylixir.Converter`;
  extracted here so additional stdlib modules can plug in via the
  `Pylixir.Stdlib` registry.
  """

  @behaviour Pylixir.Stdlib

  @unsupported_attrs ~w(inf nan)
  @unary ~w(sqrt floor ceil log log2 log10 sin cos tan asin acos atan exp)
  @binary ~w(pow atan2)

  @impl true
  def attribute(["pi"], _node), do: {:ok, {{:., [], [:math, :pi]}, [], []}}
  def attribute(["e"], _node), do: {:ok, {{:., [], [:math, :e]}, [], []}}

  def attribute(["tau"], _node),
    do: {:ok, {:*, [], [2, {{:., [], [:math, :pi]}, [], []}]}}

  def attribute([attr], _node) when attr in @unsupported_attrs,
    do:
      {:error, "`math.#{attr}` is not supported — Elixir has no inf/nan equivalents (RFC §6.19)"}

  def attribute(_path, _node), do: :no_clause

  @impl true
  # Python's `math.floor`/`math.ceil` return *int*; Erlang's
  # `:math.floor`/`:math.ceil` return float. Wrap in `trunc/1` so
  # the runtime type matches Python's. Other unary functions return
  # float in both Python and Erlang — pass through directly.
  def call(["floor"], [x], _kwargs, _node),
    do: {:ok, {:trunc, [], [{{:., [], [:math, :floor]}, [], [x]}]}}

  def call(["ceil"], [x], _kwargs, _node),
    do: {:ok, {:trunc, [], [{{:., [], [:math, :ceil]}, [], [x]}]}}

  def call([attr], [x], _kwargs, _node) when attr in @unary,
    do: {:ok, {{:., [], [:math, String.to_atom(attr)]}, [], [x]}}

  def call([attr], [a, b], _kwargs, _node) when attr in @binary,
    do: {:ok, {{:., [], [:math, String.to_atom(attr)]}, [], [a, b]}}

  # Integer-arithmetic helpers — not in Erlang's :math, but in
  # Elixir's stdlib. `math.gcd` was binary in 3.4 and variadic
  # (0..N args) in 3.9+; fold pairwise. The 1-arg / 0-arg cases
  # match Python: gcd() == 0, gcd(a) == abs(a).
  def call(["gcd"], [], _kwargs, _node), do: {:ok, 0}

  def call(["gcd"], [a], _kwargs, _node),
    do: {:ok, {{:., [], [{:__aliases__, [], [:Kernel]}, :abs]}, [], [a]}}

  def call(["gcd"], [a, b], _kwargs, _node),
    do: {:ok, {{:., [], [{:__aliases__, [], [:Integer]}, :gcd]}, [], [a, b]}}

  def call(["gcd"], args, _kwargs, _node) when length(args) > 2,
    do: {:ok, {:py_math_gcd, [], [args]}}

  # `math.isqrt(n)` — floor of integer square root. Erlang's :math.sqrt
  # is a float op, so we trunc; precision loss for n > 2^53 is the
  # known tradeoff (Python's exact-arithmetic isqrt would need a
  # Newton-iteration helper).
  def call(["isqrt"], [n], _kwargs, _node),
    do: {:ok, {:trunc, [], [{{:., [], [:math, :sqrt]}, [], [n]}]}}

  # `math.comb(n, k)` — binomial coefficient n! / (k! * (n-k)!). Pure
  # integer math via py_math_comb runtime helper (multiplicative
  # formula; doesn't overflow for the inputs Python actually feeds it
  # since BEAM integers are arbitrary-precision).
  def call(["comb"], [n, k], _kwargs, _node),
    do: {:ok, {:py_math_comb, [], [n, k]}}

  # `math.factorial(n)` — n!. Integer.gcd-style: same arbitrary-precision
  # benefit; defers to runtime helper.
  def call(["factorial"], [n], _kwargs, _node),
    do: {:ok, {:py_math_factorial, [], [n]}}

  # `math.hypot(x, y, ...)` — Euclidean norm sqrt(sum(xi**2)). Variadic
  # in Python 3.8+; routes through a list-taking helper. The Pylixir
  # call site wraps the args in a list literal so this works for any
  # arity ≥ 1.
  def call(["hypot"], args, _kwargs, _node) when args != [],
    do: {:ok, {:py_math_hypot, [], [args]}}

  # `math.log(x)` already routes through @unary (natural log).
  # `math.log(x, base)` — explicit-base log. Lower to log(x) / log(base).
  def call(["log"], [x, base], _kwargs, _node) do
    log_x = {{:., [], [:math, :log]}, [], [x]}
    log_b = {{:., [], [:math, :log]}, [], [base]}
    {:ok, {:/, [], [log_x, log_b]}}
  end

  # Angle conversion: `math.degrees(rad)` → rad * 180 / pi.
  # `math.radians(deg)` → deg * pi / 180.
  def call(["degrees"], [rad], _kwargs, _node) do
    pi = {{:., [], [:math, :pi]}, [], []}
    {:ok, {:/, [], [{:*, [], [rad, 180]}, pi]}}
  end

  def call(["radians"], [deg], _kwargs, _node) do
    pi = {{:., [], [:math, :pi]}, [], []}
    {:ok, {:/, [], [{:*, [], [deg, pi]}, 180]}}
  end

  # `math.trunc(x)` — truncate toward zero, returns int.
  def call(["trunc"], [x], _kwargs, _node), do: {:ok, {:trunc, [], [x]}}

  # `math.fabs(x)` — absolute value, always float.
  def call(["fabs"], [x], _kwargs, _node),
    do: {:ok, {{:., [], [:erlang, :abs]}, [], [{:*, [], [x, 1.0]}]}}

  # `math.copysign(x, y)` — magnitude of x with sign of y. Python
  # always returns a float; coerce via `* 1.0` so integer inputs lift.
  def call(["copysign"], [x, y], _kwargs, _node) do
    abs_x = {{:., [], [:erlang, :abs]}, [], [{:*, [], [x, 1.0]}]}

    {:ok,
     {:if, [],
      [
        {:>=, [], [y, 0]},
        [do: abs_x, else: {:-, [], [abs_x]}]
      ]}}
  end

  # `math.prod(iterable[, start])` — product of all elements. Defaults
  # to `start=1`, matching Python. Empty iterable returns `start`.
  def call(["prod"], [iter], _kwargs, _node),
    do: {:ok, {:py_math_prod, [], [iter, 1]}}

  def call(["prod"], [iter, start], _kwargs, _node),
    do: {:ok, {:py_math_prod, [], [iter, start]}}

  # `math.lcm(*ints)` — least common multiple. Variadic in 3.9+;
  # zero args → 1, one arg → abs(a). Routes through a list-taking
  # helper; the call site wraps args in a list literal.
  def call(["lcm"], args, _kwargs, _node) when is_list(args),
    do: {:ok, {:py_math_lcm, [], [args]}}

  # `math.dist(p, q)` — Euclidean distance between two iterables of
  # equal length. Lowers to sqrt(sum((pi - qi)^2)). Routes via helper
  # so we accept any iterable, not just lists.
  def call(["dist"], [p, q], _kwargs, _node),
    do: {:ok, {:py_math_dist, [], [p, q]}}

  # `math.modf(x)` — returns `(fractional_part, integer_part)` both as
  # floats. `math.frexp(x)` — returns `(mantissa, exponent)` such that
  # `x == mantissa * 2 ** exponent` with `0.5 <= abs(m) < 1`. Both lower
  # to runtime helpers; the IEEE-bit-manipulation in py_math_frexp is
  # too gnarly to inline at the call site.
  def call(["modf"], [x], _kwargs, _node), do: {:ok, {:py_math_modf, [], [x]}}
  def call(["frexp"], [x], _kwargs, _node), do: {:ok, {:py_math_frexp, [], [x]}}

  def call([attr], args, _kwargs, _node) when attr in @unary or attr in @binary,
    do:
      {:error,
       "math.#{attr}/#{length(args)} is not supported (supported: #{Enum.join(@unary, "/1, ")}/1 + #{Enum.join(@binary, "/2, ")}/2)"}

  def call(_path, _args, _kwargs, _node), do: :no_clause

  # --- from math import <name> ----------------------------------------
  #
  # Several math names produce non-trivial AST (e.g. `floor` wraps with
  # `trunc`), so a `&py_floor/1` capture wouldn't be right. Re-use
  # `call/4` to synthesize a fn over fresh params — keeps the lowering
  # in one place.

  @unary_arity ~w(sqrt floor ceil log log2 log10 sin cos tan asin acos atan exp isqrt factorial)
  @binary_arity ~w(pow atan2 gcd comb)

  @impl true
  def import_binding(name) when name in @unary_arity, do: synth_fn(name, 1)
  def import_binding(name) when name in @binary_arity, do: synth_fn(name, 2)
  def import_binding(_), do: :error

  defp synth_fn(name, arity) do
    params = Enum.map(1..arity, fn i -> {String.to_atom("a#{i}"), [], nil} end)
    {:ok, body} = call([name], params, %{}, %{"_type" => "Call", "lineno" => nil})
    {:ok, {:fn, [], [{:->, [], [params, body]}]}}
  end
end
