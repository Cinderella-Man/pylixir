defmodule Pylixir.Nodes.AttributeMethods do
  @moduledoc """
  Lower Python method calls on a runtime value: `target.method(args)`
  where `target` is *not* a registered `Pylixir.Stdlib` module. Covers
  Python's dict methods (`.keys()`, `.get(k)`), string methods
  (`.lower()`, `.split(sep)`, …), and the join arg-swap
  (`sep.join(items)` → `Enum.join(items, sep)`).

  ## Ducktyping is the contract

  Unlike `Pylixir.Stdlib` (which keys off a module name known at
  codegen time), this module keys off `(method_name, target_arity)`
  alone — the target's *type* isn't known statically. We trust the
  Python source: `.append` is only ever called on a list,
  `.lower` only on a string. Collisions (e.g. `.pop` exists on both
  list and dict) currently resolve to whichever implementation is
  emitted by the matching clause; if the call site uses the "wrong"
  type the generated code will fail at runtime.

  ## Why it sits *outside* `Pylixir.Lowering`

  `Lowering.result()` keys on a namespace path (`["math", "sqrt"]`,
  `["sys", "stdin", "read"]`). Method dispatch's key is structurally
  different (`(target_ast, method_name)`), so forcing them under one
  protocol would obscure both — see the conversation in the
  improve-codebase-architecture review for the full reasoning.

  ## Why this module isn't split per Python-type (Str/Dict/Set/Int)

  Considered and rejected in the 2026-05-17 architecture review.
  Dispatch is by *method name only* — we don't know the receiver type
  at codegen time, and several Python types share method names
  (`.pop` on list/dict/set, `.count` on str/list). Splitting per-type
  would force a method-name dispatcher that tries each per-type
  module in turn — moving indirection without improving locality.
  The flat `do_dispatch/5` table here, organised by `# ---` section
  comments per Python type, keeps "find the lowering for method X"
  to one grep. The `@*_methods` lists feed the catch-all hint
  message so users see the allowed surface at the right moment.
  """

  alias Pylixir.UnsupportedNodeError

  @dict_methods ~w(keys values items get)
  @string_methods ~w(lower upper title capitalize swapcase casefold
                     strip lstrip rstrip startswith endswith
                     split replace find rfind count index zfill isdigit isalpha isalnum
                     islower isupper isspace isdecimal isnumeric isascii
                     join splitlines read readline
                     ljust rjust center partition rpartition
                     removeprefix removesuffix)
  # Methods that are no-ops under Elixir's immutability — Python's
  # `xs.copy()` returns a shallow copy so subsequent mutations on the
  # copy don't affect the original; Elixir's containers are already
  # immutable, so the existing mutation-rewrite (`xs = xs ++ [y]` etc.)
  # already preserves the original. `.copy()` lowers to its target.
  @noop_methods ~w(copy)

  # Methods on Python's `int`. Pylixir's dispatch is ducktyped — these
  # are emitted assuming the target is an integer; the runtime helper
  # has integer guards so non-integer targets crash visibly.
  @int_methods ~w(bit_length)

  # Methods on Python's `set` / `frozenset` — Elixir's MapSet provides
  # exact equivalents. Same ducktyping caveat: non-MapSet targets
  # crash at runtime.
  @set_methods ~w(union intersection difference symmetric_difference
                  issubset issuperset isdisjoint pop)

  @spec dispatch(String.t(), Macro.t(), [Macro.t()], map(), map()) :: Macro.t()
  def dispatch(attr, target_ast, arg_asts, kwargs, node) do
    do_dispatch(attr, target_ast, arg_asts, kwargs, node)
  end

  # --- Immutability no-ops -----------------------------------------------

  # `xs.copy()` / `d.copy()` / `s.copy()` — Elixir is immutable, so the
  # copy is the value itself. The target_ast is emitted *as the
  # expression* — single-eval semantics are preserved because the
  # surrounding expression evaluates it once.
  defp do_dispatch("copy", target, [], _kw, _node), do: target

  # --- Integer methods ---------------------------------------------------

  defp do_dispatch("bit_length", target, [], _kw, _node),
    do: {:py_int_bit_length, [], [target]}

  # --- Set methods (Python set / frozenset → Elixir MapSet) -------------

  # `(expr).pop(…)` — expression-receiver form, no rebind possible
  # (e.g. `(s1 - s2).pop()`, or `d.pop(k)` inside `print(d.pop(k))`).
  # Lowers to value-only helpers — the rebind happens only when the
  # form is the Assign RHS (handled in `Pylixir.Nodes.Assign`).
  defp do_dispatch("pop", target, [], _kw, _node), do: {:py_pop_any, [], [target]}

  defp do_dispatch("pop", target, [key], _kw, _node),
    do: {:py_pop_value, [], [target, key]}

  defp do_dispatch("pop", target, [key, default], _kw, _node),
    do: {:py_pop_value_default, [], [target, key, default]}

  defp do_dispatch("union", target, [other], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:MapSet]}, :union]}, [], [target, other]}

  defp do_dispatch("intersection", target, [other], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:MapSet]}, :intersection]}, [], [target, other]}

  defp do_dispatch("difference", target, [other], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:MapSet]}, :difference]}, [], [target, other]}

  defp do_dispatch("symmetric_difference", target, [other], _kw, _node) do
    # MapSet has no direct symmetric_difference; compose via two
    # differences + union (same as the `py_bxor` helper's set arm).
    diff_ab = {{:., [], [{:__aliases__, [], [:MapSet]}, :difference]}, [], [target, other]}
    diff_ba = {{:., [], [{:__aliases__, [], [:MapSet]}, :difference]}, [], [other, target]}
    {{:., [], [{:__aliases__, [], [:MapSet]}, :union]}, [], [diff_ab, diff_ba]}
  end

  defp do_dispatch("issubset", target, [other], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:MapSet]}, :subset?]}, [], [target, other]}

  defp do_dispatch("issuperset", target, [other], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:MapSet]}, :subset?]}, [], [other, target]}

  defp do_dispatch("isdisjoint", target, [other], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:MapSet]}, :disjoint?]}, [], [target, other]}

  # --- String formatting -------------------------------------------------

  # `"<template>".format(args...)` — handled only when the template is a
  # *literal* string (the common case) so we can parse the spec at
  # codegen time. Supported templates: `{}` / `{0}` (bare positional),
  # `{:.Nf}` / `{0:.Nf}` (float with N decimal places). Other shapes
  # raise with a clearer hint.
  defp do_dispatch("format", template, args, _kw, node) when is_binary(template) do
    case parse_format_template(template) do
      {:bare_pos, idx} when idx < length(args) ->
        {:py_str, [], [Enum.at(args, idx)]}

      {:float_fixed, idx, decimals} when idx < length(args) ->
        # `:erlang.float_to_binary/2` is the non-deprecated path
        # (Elixir's `Float.to_string/2` deprecated 2024). Note: rounds
        # half-up, not banker's — Python's `.format` uses banker's, so
        # `{:.0f}".format(2.5)` differs (`3` here vs `2` in Python).
        # Higher-precision uses (the eval-corpus shapes `{:.6f}`,
        # `{:.9f}`) don't hit the disagreement.
        coerced = {:py_float, [], [Enum.at(args, idx)]}

        {{:., [], [:erlang, :float_to_binary]}, [], [coerced, [decimals: decimals]]}

      _ ->
        raise UnsupportedNodeError,
          node_type: "Call",
          hint:
            "`\"#{template}\".format(...)` — only `{}` / `{N}` / `{:.Nf}` / `{N:.Nf}` " <>
              "single-placeholder forms are supported at codegen time",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  defp do_dispatch("format", _target, _args, _kw, node) do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint:
        "`.format(...)` is only supported when the template is a literal string with one of: " <>
          "`{}` / `{N}` / `{:.Nf}` / `{N:.Nf}`",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # --- T28 dict methods --------------------------------------------------

  defp do_dispatch("keys", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:Map]}, :keys]}, [], [target]}

  defp do_dispatch("values", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:Map]}, :values]}, [], [target]}

  defp do_dispatch("items", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:Map]}, :to_list]}, [], [target]}

  defp do_dispatch("get", target, [k], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:Map]}, :get]}, [], [target, k]}

  defp do_dispatch("get", target, [k, default], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:Map]}, :get]}, [], [target, k, default]}

  # --- T29a string methods: case / whitespace / prefix-suffix / join ----

  defp do_dispatch("lower", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :downcase]}, [], [target]}

  defp do_dispatch("upper", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :upcase]}, [], [target]}

  # Python's `str.title()` — capitalises first letter of every "word"
  # (run of alpha chars). `str.capitalize()` — only the first char of
  # the whole string. `str.swapcase()` — flip case per char.
  # `str.casefold()` — like lower but more aggressive for Unicode
  # (Elixir's String.downcase/2 :default mode is the closest match).
  defp do_dispatch("title", target, [], _kw, _node), do: {:py_str_title, [], [target]}

  defp do_dispatch("capitalize", target, [], _kw, _node),
    do: {:py_str_capitalize, [], [target]}

  defp do_dispatch("swapcase", target, [], _kw, _node), do: {:py_str_swapcase, [], [target]}

  defp do_dispatch("casefold", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :downcase]}, [], [target]}

  # Python's `str.ljust(width[, fill])` / `str.rjust(width[, fill])` /
  # `str.center(width[, fill])` — pad to `width` with optional fill
  # char (default space). Returns unchanged when `width <= len(s)`.
  # `center` reuses `py_center_pad/3` (also used by the f-string
  # format-spec parser).
  defp do_dispatch("ljust", target, [width], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :pad_trailing]}, [], [target, width]}

  defp do_dispatch("ljust", target, [width, fill], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :pad_trailing]}, [], [target, width, fill]}

  defp do_dispatch("rjust", target, [width], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :pad_leading]}, [], [target, width]}

  defp do_dispatch("rjust", target, [width, fill], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :pad_leading]}, [], [target, width, fill]}

  defp do_dispatch("center", target, [width], _kw, _node),
    do: {:py_center_pad, [], [target, width, " "]}

  defp do_dispatch("center", target, [width, fill], _kw, _node),
    do: {:py_center_pad, [], [target, width, fill]}

  # Python's `str.partition(sep)` — split into `(before, sep, after)`.
  # When `sep` isn't found: `(string, "", "")`. `rpartition` is the
  # right-anchored variant: not found gives `("", "", string)`.
  defp do_dispatch("partition", target, [sep], _kw, _node),
    do: {:py_str_partition, [], [target, sep]}

  defp do_dispatch("rpartition", target, [sep], _kw, _node),
    do: {:py_str_rpartition, [], [target, sep]}

  # Python 3.9+ `str.removeprefix(p)` / `str.removesuffix(s)` — strip
  # exactly one occurrence if it's there; otherwise return unchanged.
  # NOT the same as `lstrip(p)` (which strips a *set* of chars
  # repeatedly).
  defp do_dispatch("removeprefix", target, [prefix], _kw, _node),
    do: {:py_str_remove_prefix, [], [target, prefix]}

  defp do_dispatch("removesuffix", target, [suffix], _kw, _node),
    do: {:py_str_remove_suffix, [], [target, suffix]}

  # 0-arg form: trim whitespace via Elixir's `String.trim*`.
  defp do_dispatch("strip", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :trim]}, [], [target]}

  defp do_dispatch("lstrip", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :trim_leading]}, [], [target]}

  defp do_dispatch("rstrip", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :trim_trailing]}, [], [target]}

  # 1-arg form: `s.strip("abc")` in Python treats the arg as a SET
  # of chars to strip from each end repeatedly — NOT a substring.
  # Elixir's `String.trim/2` strips exactly that string, so we route
  # through a runtime helper that does the char-set semantics.
  defp do_dispatch("strip", target, [chars], _kw, _node),
    do: {:py_str_strip_chars, [], [target, chars]}

  defp do_dispatch("lstrip", target, [chars], _kw, _node),
    do: {:py_str_lstrip_chars, [], [target, chars]}

  defp do_dispatch("rstrip", target, [chars], _kw, _node),
    do: {:py_str_rstrip_chars, [], [target, chars]}

  defp do_dispatch("startswith", target, [prefix], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :starts_with?]}, [], [target, prefix]}

  defp do_dispatch("endswith", target, [suffix], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :ends_with?]}, [], [target, suffix]}

  # sep.join(items) — RFC §10.1 arg-swap (Python: sep.join(items); Elixir: Enum.join(items, sep))
  defp do_dispatch("join", sep, [items], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:Enum]}, :join]}, [], [items, sep]}

  # --- T29b string methods: search / split / replace / classification ---

  defp do_dispatch("split", target, [], _kw, _node) do
    # No args: split on whitespace.
    {{:., [], [{:__aliases__, [], [:String]}, :split]}, [], [target]}
  end

  defp do_dispatch("split", _target, [""], _kw, node) do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint:
        "str.split(\"\") is unsupported (Python raises ValueError; Elixir would behave differently — RFC §6.20)",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp do_dispatch("split", target, [sep], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :split]}, [], [target, sep]}

  defp do_dispatch("split", target, [sep, maxsplit], _kw, _node),
    do:
      {{:., [], [{:__aliases__, [], [:String]}, :split]}, [],
       [target, sep, [parts: {:+, [], [maxsplit, 1]}]]}

  defp do_dispatch("replace", target, [old, new], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :replace]}, [], [target, old, new]}

  defp do_dispatch("replace", target, [old, new, 1], _kw, _node),
    do:
      {{:., [], [{:__aliases__, [], [:String]}, :replace]}, [],
       [target, old, new, [global: false]]}

  defp do_dispatch("replace", _target, [_old, _new, count], _kw, node)
       when is_integer(count) and count > 1 do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint:
        "str.replace(old, new, count) with count>1 is not supported (RFC §6.23); use count=1 or omit",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # `str.find(sub[, start[, end]])` — returns the leftmost index of
  # `sub` in the slice `s[start:end]` (translated to absolute), or -1.
  defp do_dispatch("find", target, [sub], _kw, _node),
    do: {:py_str_find, [], [target, sub]}

  defp do_dispatch("find", target, [sub, start], _kw, _node),
    do: {:py_str_find, [], [target, sub, start]}

  defp do_dispatch("find", target, [sub, start, stop], _kw, _node),
    do: {:py_str_find, [], [target, sub, start, stop]}

  # `str.rfind(sub[, start[, end]])` — rightmost index, otherwise -1.
  defp do_dispatch("rfind", target, [sub], _kw, _node),
    do: {:py_str_rfind, [], [target, sub]}

  defp do_dispatch("rfind", target, [sub, start], _kw, _node),
    do: {:py_str_rfind, [], [target, sub, start]}

  defp do_dispatch("rfind", target, [sub, start, stop], _kw, _node),
    do: {:py_str_rfind, [], [target, sub, start, stop]}

  defp do_dispatch("count", target, [sub], _kw, _node),
    do: {:py_str_count, [], [target, sub]}

  defp do_dispatch("index", target, [sub], _kw, _node),
    do: {:py_str_index, [], [target, sub]}

  defp do_dispatch("zfill", target, [width], _kw, _node) do
    # "5".zfill(3) → "005". Elixir's String.pad_leading/3 with "0".
    {{:., [], [{:__aliases__, [], [:String]}, :pad_leading]}, [], [target, width, "0"]}
  end

  defp do_dispatch("isdigit", target, [], _kw, _node) do
    {:&&, [], [{:!=, [], [target, ""]}, regex_match(target, "^[0-9]+$")]}
  end

  defp do_dispatch("isalpha", target, [], _kw, _node) do
    {:&&, [], [{:!=, [], [target, ""]}, regex_match(target, "^[A-Za-z]+$")]}
  end

  defp do_dispatch("isalnum", target, [], _kw, _node) do
    {:&&, [], [{:!=, [], [target, ""]}, regex_match(target, "^[A-Za-z0-9]+$")]}
  end

  # `str.islower()` — non-empty AND all cased chars are lowercase AND
  # at least one cased char exists. `str.isupper()` is the mirror.
  # Both delegate to a runtime helper so the "at least one cased char"
  # check stays correct against strings like " ", "123" (those return
  # False in Python, but a pure regex check would say True).
  defp do_dispatch("islower", target, [], _kw, _node), do: {:py_str_islower, [], [target]}
  defp do_dispatch("isupper", target, [], _kw, _node), do: {:py_str_isupper, [], [target]}

  # `str.isspace()` — non-empty AND every char is whitespace.
  defp do_dispatch("isspace", target, [], _kw, _node) do
    {:&&, [], [{:!=, [], [target, ""]}, regex_match(target, "^[[:space:]]+$")]}
  end

  # `str.isdecimal()` / `str.isnumeric()` — Pylixir conflates both with
  # isdigit for simplicity (Unicode distinctions don't matter for the
  # ASCII inputs competitive code feeds).
  defp do_dispatch("isdecimal", target, [], _kw, _node) do
    {:&&, [], [{:!=, [], [target, ""]}, regex_match(target, "^[0-9]+$")]}
  end

  defp do_dispatch("isnumeric", target, [], _kw, _node) do
    {:&&, [], [{:!=, [], [target, ""]}, regex_match(target, "^[0-9]+$")]}
  end

  # `str.isascii()` — empty OR all chars are ASCII (< 0x80).
  defp do_dispatch("isascii", target, [], _kw, _node) do
    {:||, [], [{:==, [], [target, ""]}, regex_match(target, "^[\\x00-\\x7f]+$")]}
  end

  # Python's `str.splitlines()` — split on `\r\n`, `\r`, `\n`, and other
  # Unicode line boundaries; the trailing newline doesn't produce a
  # final empty entry. `str.splitlines(keepends=True)` not supported.
  defp do_dispatch("splitlines", target, [], _kw, _node),
    do: {:py_str_splitlines, [], [target]}

  # Stdin attribute calls — both `sys.stdin.read()` (via Stdlib.Sys
  # multi-segment) and `stdin.read()` (after `from sys import stdin`)
  # end up here when the receiver is the `stdin` sentinel. The receiver
  # is discarded (we don't model stdin as a real object — just a flag
  # for "next read goes through Erlang's stdio").
  defp do_dispatch("read", _target, [], _kw, _node), do: {:py_stdin_read, [], []}
  defp do_dispatch("readline", _target, [], _kw, _node), do: {:py_stdin_readline, [], []}

  defp do_dispatch(attr, _target, _args, _kw, node) do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint:
        "method `.#{attr}()` is not supported (allowed: #{Enum.join(@dict_methods ++ @string_methods ++ @noop_methods ++ @int_methods ++ @set_methods, ", ")})",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  # Classify a `.format()` template literal into one of the supported
  # shapes. Returns `{:bare_pos, idx}` or `{:float_fixed, idx, decimals}`
  # or `:unsupported`. The default index when omitted is `0`.
  defp parse_format_template(template) do
    cond do
      template == "{}" ->
        {:bare_pos, 0}

      Regex.match?(~r/^\{(\d+)\}$/, template) ->
        [_, idx] = Regex.run(~r/^\{(\d+)\}$/, template)
        {:bare_pos, String.to_integer(idx)}

      Regex.match?(~r/^\{:\.(\d+)f\}$/, template) ->
        [_, n] = Regex.run(~r/^\{:\.(\d+)f\}$/, template)
        {:float_fixed, 0, String.to_integer(n)}

      Regex.match?(~r/^\{(\d+):\.(\d+)f\}$/, template) ->
        [_, idx, n] = Regex.run(~r/^\{(\d+):\.(\d+)f\}$/, template)
        {:float_fixed, String.to_integer(idx), String.to_integer(n)}

      true ->
        :unsupported
    end
  end

  defp regex_match(target, pattern) do
    {{:., [], [{:__aliases__, [], [:Regex]}, :match?]}, [],
     [{:sigil_r, [], [{:<<>>, [], [pattern]}, []]}, target]}
  end

end
