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

  # Python's `math.prod(iter, start=1)` — product of all elements.
  # `start` defaults to 1 (so an empty iter returns 1, matching Python).
  # No type-coercion: int*int stays int, float*anything goes float —
  # mirrors Python's `*` semantics.
  def py_math_prod(iter, start) when is_list(iter),
    do: Enum.reduce(iter, start, fn x, acc -> acc * x end)

  def py_math_prod(iter, start) when is_tuple(iter),
    do: py_math_prod(Tuple.to_list(iter), start)

  def py_math_prod(iter, start),
    do: py_math_prod(Enum.to_list(iter), start)

  # Python's variadic `math.gcd(*ints)` for arity ≥ 3. Folds pairwise
  # via Integer.gcd; matches Python (gcd reaches 1 → result is 1 from
  # there on, so the reduce can't get more efficient by early-exit
  # without a custom loop — not worth it for typical input sizes).
  def py_math_gcd(ints) when is_list(ints),
    do: Enum.reduce(ints, 0, fn x, acc -> Integer.gcd(acc, x) end)

  # Python's variadic `math.lcm(*ints)`. lcm() == 1, lcm(a) == abs(a),
  # lcm(0, ...) == 0, otherwise fold pairwise via `a*b div gcd(a,b)`.
  # Caller wraps args in a list literal so this works at any arity.
  def py_math_lcm([]), do: 1
  def py_math_lcm([a]) when is_integer(a), do: abs(a)
  def py_math_lcm([a, b | rest]), do: py_math_lcm([py_lcm_pair(a, b) | rest])

  def py_lcm_pair(0, _), do: 0
  def py_lcm_pair(_, 0), do: 0

  def py_lcm_pair(a, b) when is_integer(a) and is_integer(b),
    do: div(abs(a * b), Integer.gcd(a, b))

  # Python's `math.dist(p, q)` — Euclidean distance between two
  # equal-length iterables of coords. sqrt(sum((pi - qi)^2)). Returns
  # float; matches Python's float-only output even for int coords.
  def py_math_dist(p, q) do
    p_list = py_dist_to_list(p)
    q_list = py_dist_to_list(q)

    sum =
      Enum.zip(p_list, q_list)
      |> Enum.reduce(0.0, fn {a, b}, acc ->
        d = a - b
        acc + d * d
      end)

    :math.sqrt(sum)
  end

  def py_dist_to_list(t) when is_tuple(t), do: Tuple.to_list(t)
  def py_dist_to_list(l) when is_list(l), do: l
  def py_dist_to_list(other), do: Enum.to_list(other)

  # Python's `math.modf(x)` — `(fractional_part, integer_part)` both
  # as floats. `trunc/1` matches Python's behaviour (toward zero); the
  # `* 1.0` coercions lift integers and ensure both elements are
  # floats even when the input is integer.
  def py_math_modf(x) when is_number(x) do
    x_f = x * 1.0
    i_part = trunc(x_f) * 1.0
    f_part = x_f - i_part
    {f_part, i_part}
  end

  # Python's `math.frexp(x)` — returns `(mantissa, exponent)` with
  # `0.5 <= |mantissa| < 1` (or `(0.0, 0)` for zero). Implemented by
  # unpacking the IEEE-754 binary64 representation: take the sign and
  # fraction bits, rewrite the biased exponent to 1022 so the implicit
  # `1.frac` value lands in `[0.5, 1.0)`, and return the original
  # exponent shifted by 1022. Subnormals (exp_raw == 0) and infinities
  # /NaN aren't special-cased — math code that hits them is rare and
  # Python's behaviour there is mostly platform-defined anyway.
  def py_math_frexp(x) when x == 0, do: {0.0, 0}

  def py_math_frexp(x) when is_number(x) do
    x_f = x * 1.0
    <<sign::1, exp_raw::11, frac::52>> = <<x_f::float-64>>
    <<m::float-64>> = <<sign::1, 1022::11, frac::52>>
    {m, exp_raw - 1022}
  end

  # Python's 3-arg `pow(base, exp, mod)` — modular exponentiation.
  # Uses Erlang's :crypto.mod_pow (square-and-multiply, suitable for
  # large exponents used in number-theoretic code like modular inverses
  # via Fermat's little theorem).
  def py_pow_mod(base, exp, mod)
      when is_integer(base) and is_integer(exp) and is_integer(mod) and exp >= 0 and mod > 0 do
    # `:crypto.mod_pow` mishandles a negative base (it round-trips the
    # term through an unsigned-binary encoding). Python reduces the
    # base modulo `mod` first, landing the result in [0, mod), so do
    # the same here. `Integer.mod` already gives a non-negative result.
    :crypto.mod_pow(Integer.mod(base, mod), exp, mod) |> :crypto.bytes_to_integer()
  end

  # Negative exponent (Python 3.8+): `pow(b, -1, m)` is the modular inverse
  # of `b` mod `m`, and `pow(b, -k, m)` is that inverse to the k-th power
  # mod `m`. Requires `b` invertible mod `m` (gcd == 1) — Python raises
  # ValueError otherwise; we surface an ArithmeticError.
  def py_pow_mod(base, exp, mod)
      when is_integer(base) and is_integer(exp) and is_integer(mod) and exp < 0 and mod > 0 do
    inv = py_mod_inverse(Integer.mod(base, mod), mod)
    py_pow_mod(inv, -exp, mod)
  end

  # Modular inverse via the extended Euclidean algorithm. `a` is assumed
  # already reduced into `[0, m)`.
  def py_mod_inverse(a, m) do
    case py_ext_gcd(a, m) do
      {1, x, _y} -> Integer.mod(x, m)
      _ -> raise ArithmeticError, "base is not invertible for the given modulus"
    end
  end

  # Returns `{g, x, y}` with `a*x + b*y == g == gcd(a, b)`.
  def py_ext_gcd(0, b), do: {b, 0, 1}

  def py_ext_gcd(a, b) do
    {g, x, y} = py_ext_gcd(Integer.mod(b, a), a)
    {g, y - div(b, a) * x, x}
  end

  # --- HELPERS END ---
end
