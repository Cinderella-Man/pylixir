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
  # Elixir's stdlib.
  def call(["gcd"], [a, b], _kwargs, _node),
    do: {:ok, {{:., [], [{:__aliases__, [], [:Integer]}, :gcd]}, [], [a, b]}}

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
