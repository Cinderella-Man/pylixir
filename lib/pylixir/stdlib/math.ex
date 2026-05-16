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

  def call([attr], args, _kwargs, _node) when attr in @unary or attr in @binary,
    do:
      {:error,
       "math.#{attr}/#{length(args)} is not supported (supported: #{Enum.join(@unary, "/1, ")}/1 + #{Enum.join(@binary, "/2, ")}/2)"}

  def call(_path, _args, _kwargs, _node), do: :no_clause
end
