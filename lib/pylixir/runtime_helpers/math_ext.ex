defmodule Pylixir.RuntimeHelpers.MathExt do
  @moduledoc """
  Runtime helpers for math operations beyond `:math` BIFs:
  `math.comb`, `math.factorial`, `math.hypot`, and the 3-arg modular
  `pow(base, exp, mod)`. Lives in its own file because the
  multiplicative-formula `comb` and modular-exponentiation `pow_mod`
  are arithmetic specialties that don't share helpers with the
  arithmetic core in `Pylixir.RuntimeHelpers`.

  All defs are spliced into every generated `TranslatedCode` module
  via `Pylixir.HelpersCodegen`.
  """

  # --- HELPERS START ---

  # Python's `math.comb(n, k)` — binomial coefficient. Multiplicative
  # formula (avoids huge factorials): C(n, k) = product_{i=1..k} (n-k+i) / i.
  # Returns 0 when k > n or k < 0 (matches Python).
  def py_math_comb(n, k) when is_integer(n) and is_integer(k) do
    cond do
      k < 0 or k > n -> 0
      k == 0 or k == n -> 1
      true -> py_math_comb_loop(n, min(k, n - k), 1, 1)
    end
  end

  def py_math_comb_loop(_n, 0, acc, _i), do: acc

  def py_math_comb_loop(n, k, acc, i) do
    acc = div(acc * (n - i + 1), i)
    py_math_comb_loop(n, k - 1, acc, i + 1)
  end

  # Python's `math.factorial(n)`. BEAM integers are arbitrary-precision;
  # no overflow risk. Negative input raises (mirrors Python's ValueError).
  def py_math_factorial(0), do: 1
  def py_math_factorial(n) when is_integer(n) and n > 0,
    do: Enum.reduce(1..n, 1, &(&1 * &2))

  # Variadic `math.hypot(*coords)` — Euclidean norm sqrt(sum(xi**2)).
  # Caller wraps args in a list literal; we reduce + sqrt.
  def py_math_hypot(coords) when is_list(coords) do
    sum = Enum.reduce(coords, 0.0, fn x, acc -> acc + x * x end)
    :math.sqrt(sum)
  end

  # Python's 3-arg `pow(base, exp, mod)` — modular exponentiation.
  # Uses Erlang's :crypto.mod_pow (square-and-multiply, suitable for
  # large exponents used in number-theoretic code like modular inverses
  # via Fermat's little theorem).
  def py_pow_mod(base, exp, mod)
      when is_integer(base) and is_integer(exp) and is_integer(mod) and exp >= 0 and mod > 0 do
    :crypto.mod_pow(base, exp, mod) |> :crypto.bytes_to_integer()
  end

  # --- HELPERS END ---
end
