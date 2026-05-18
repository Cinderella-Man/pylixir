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

  @dict_methods ~w(keys values items get fromkeys popitem clear)
  @string_methods ~w(lower upper title capitalize swapcase casefold
                     strip lstrip rstrip startswith endswith
                     split rsplit replace find rfind count index zfill isdigit isalpha isalnum
                     islower isupper isspace isdecimal isnumeric isascii
                     join splitlines read readline
                     ljust rjust center partition rpartition
                     removeprefix removesuffix encode decode
                     format format_map expandtabs translate maketrans)
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
                  issubset issuperset isdisjoint pop popleft)

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

  # `coll.popleft()` in expression context (`prev = pos[i].popleft()`,
  # `print(d.popleft())`) — returns the first element of the deque
  # (Pylixir's deque backing is a plain Elixir list, so this is just
  # `hd/1`). The rebind happens only when the receiver is a bare Name
  # in Assign RHS (see `Pylixir.Nodes.Assign`); the expression form
  # here drops the mutation, same trade-off as `.pop()` expression-
  # context.
  defp do_dispatch("popleft", target, [], _kw, _node), do: {:hd, [], [target]}

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

  # `"<template>".format(args...)` — handled when the template is a
  # *literal* string (the common case). Supported placeholder shapes:
  #
  #   * `{}`        — auto-positional (next available arg)
  #   * `{N}`       — explicit positional index
  #   * `{name}`    — keyword arg lookup
  #   * `{...:SPEC}` — any of the above with a format spec, dispatched
  #     to `py_format_value/2` at runtime (same spec parser the f-string
  #     code uses).
  #
  # Mix-and-match within a template is fine: `"{} {1}".format(a, b)`
  # works (auto-position grabs args[0], `{1}` grabs args[1]). Templates
  # that aren't literal strings raise with a clear hint.
  defp do_dispatch("format", template, args, kw, node) when is_binary(template) do
    case parse_format_segments(template) do
      {:ok, segments} ->
        build_format_concat(segments, args, kw, template, node)

      {:error, reason} ->
        raise UnsupportedNodeError,
          node_type: "Call",
          hint: "`\"#{template}\".format(...)` — #{reason}",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  # `template.format_map(mapping)` — like `format(**mapping)` but the
  # mapping is a runtime value (not unpacked kwargs). We can't resolve
  # placeholders at compile time, so route to a runtime helper that
  # parses the template + substitutes. Template can be any string
  # expression here (not restricted to literal); helper handles all.
  defp do_dispatch("format_map", template, [mapping], _kw, _node),
    do: {:py_str_format_map, [], [template, mapping]}

  defp do_dispatch("format", _target, _args, _kw, node) do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint: "`.format(...)` is only supported when the template is a literal string",
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

  # `d.fromkeys(keys[, default])` — usually called as `dict.fromkeys(...)`
  # rather than on an instance, but we handle both shapes. The target
  # is ignored (Python's dict.fromkeys is essentially classmethod).
  defp do_dispatch("fromkeys", _target, [keys], _kw, _node),
    do: {:py_dict_fromkeys, [], [keys, nil]}

  defp do_dispatch("fromkeys", _target, [keys, default], _kw, _node),
    do: {:py_dict_fromkeys, [], [keys, default]}

  # `d.popitem()` in expression context — returns an arbitrary `{k, v}`
  # tuple from the dict (Python LIFO since 3.7; Pylixir picks the first
  # via `Map.to_list/1 |> hd/1`). The mutation is lost — same tradeoff
  # as the other expression-context pop variants. Assign-RHS rebind
  # form not yet implemented.
  defp do_dispatch("popitem", target, [], _kw, _node), do: {:py_dict_popitem, [], [target]}

  # `d.clear()` in expression context — returns `nil` (Python's None)
  # and loses the mutation. The bare statement form `d.clear()` rebinds
  # d to `%{}` via `Pylixir.Nodes.Mutations`. Wrap as `(_ = target;
  # nil)` so the lowered AST still references `target` — preserves any
  # side effects in the receiver and silences the unused-attribute
  # warning when the receiver is a hoistable literal.
  defp do_dispatch("clear", target, [], _kw, _node),
    do: {:__block__, [], [{:=, [], [{:_, [], nil}, target]}, nil]}

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

  # `str.encode()` / `bytes.decode()` — Pylixir collapses bytes-vs-str,
  # so both are identity transforms (the target_ast is already a
  # binary). Ignore the optional encoding/errors args. This lets common
  # patterns like `s.encode().split(b"\n")` work — split on a bytes
  # arg uses the same binary-pattern path as str.split.
  defp do_dispatch("encode", target, _args, _kw, _node), do: target
  defp do_dispatch("decode", target, _args, _kw, _node), do: target

  # `str.expandtabs([tabsize])` — replace each `\t` with spaces to
  # reach the next tab-stop column. Default tabsize is 8 (Python's
  # default). Behaviour: column tracking resets after each newline,
  # and a tab at column c expands to `tabsize - (c % tabsize)` spaces.
  defp do_dispatch("expandtabs", target, [], _kw, _node),
    do: {:py_str_expandtabs, [], [target, 8]}

  defp do_dispatch("expandtabs", target, [tabsize], _kw, _node),
    do: {:py_str_expandtabs, [], [target, tabsize]}

  # `str.maketrans(from, to)` — Python's classmethod that returns a
  # translation table (a dict {ord(from_i): ord(to_i)}). Since we
  # lower `s.translate(tbl)` to a runtime helper that walks `tbl`
  # at lookup time, we just emit the dict shape — the helper accepts
  # both Python's ord-keyed maps and the simpler char-keyed shape.
  defp do_dispatch("maketrans", _target, [from_s, to_s], _kw, _node),
    do: {:py_str_maketrans, [], [from_s, to_s]}

  # `s.translate(table)` — replace each grapheme via the table's
  # lookup. Table is the dict from `maketrans`. Missing keys leave
  # the grapheme unchanged.
  defp do_dispatch("translate", target, [table], _kw, _node),
    do: {:py_str_translate, [], [target, table]}

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

  # `startswith`/`endswith` accept a single string OR a tuple of
  # strings in Python; Elixir's `String.starts_with?/2` accepts a
  # string or a LIST. Route through runtime helpers that coerce a
  # tuple to a list when needed. When the prefix/suffix is statically
  # a string literal (a BEAM binary at this point — the Constant
  # clause emits the binary directly), drop the helper and emit the
  # Elixir BIF — the tuple-coercion branch is unreachable.
  defp do_dispatch("startswith", target, [prefix], _kw, _node) when is_binary(prefix),
    do: {{:., [], [{:__aliases__, [], [:String]}, :starts_with?]}, [], [target, prefix]}

  defp do_dispatch("startswith", target, [prefix], _kw, _node),
    do: {:py_str_startswith, [], [target, prefix]}

  defp do_dispatch("endswith", target, [suffix], _kw, _node) when is_binary(suffix),
    do: {{:., [], [{:__aliases__, [], [:String]}, :ends_with?]}, [], [target, suffix]}

  defp do_dispatch("endswith", target, [suffix], _kw, _node),
    do: {:py_str_endswith, [], [target, suffix]}

  # sep.join(items) — RFC §10.1 arg-swap (Python: sep.join(items); Elixir: Enum.join(items, sep)).
  # `py_iter_to_list/1` keeps strings/tuples/dicts/sets iterating
  # Python-style (Enum.join on a BitString crashes).
  defp do_dispatch("join", sep, [items], _kw, _node),
    do:
      {{:., [], [{:__aliases__, [], [:Enum]}, :join]}, [], [{:py_iter_to_list, [], [items]}, sep]}

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

  # `split(sep, -1)` means "no limit" in Python (matches the `split(sep)`
  # form). The literal-(-1) case is folded by the converter to the AST
  # `-1`, so we recognise it here and route to the plain `String.split/2`.
  defp do_dispatch("split", target, [sep, -1], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :split]}, [], [target, sep]}

  defp do_dispatch("split", target, [sep, maxsplit], _kw, _node),
    do:
      {{:., [], [{:__aliases__, [], [:String]}, :split]}, [],
       [target, sep, [parts: {:+, [], [maxsplit, 1]}]]}

  # `s.rsplit(sep[, maxsplit])` — split from the RIGHT. With no
  # maxsplit (or -1) it's equivalent to `split`, so route there. With
  # an explicit `maxsplit` we need true right-anchored splitting: an
  # Elixir String.split with `parts:` is left-anchored, so we route to
  # `py_str_rsplit/3` which reverses + splits + reverses-back to keep
  # the leftmost segment as the prefix-merged chunk.
  defp do_dispatch("rsplit", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :split]}, [], [target]}

  defp do_dispatch("rsplit", target, [sep], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :split]}, [], [target, sep]}

  defp do_dispatch("rsplit", target, [sep, maxsplit], _kw, _node),
    do: {:py_str_rsplit, [], [target, sep, maxsplit]}

  defp do_dispatch("replace", target, [old, new], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :replace]}, [], [target, old, new]}

  defp do_dispatch("replace", target, [old, new, 1], _kw, _node),
    do:
      {{:., [], [{:__aliases__, [], [:String]}, :replace]}, [],
       [target, old, new, [global: false]]}

  # `s.replace(old, new, count)` for any count other than the literal
  # `1` (already handled above with the global:false flag). Routes to
  # a runtime helper that walks left-to-right replacing the first
  # `count` occurrences. Handles count >= 2, count == 0 (no-op),
  # negative count (Python's "no limit"), and any non-literal count
  # expression where the codegen can't decide at compile time.
  defp do_dispatch("replace", target, [old, new, count], _kw, _node),
    do: {:py_str_replace_n, [], [target, old, new, count]}

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

  # Tokenize a .format template into segments: `{:text, "..."}` and
  # `{:placeholder, key, spec}` where:
  #   - key  = :auto | {:index, N} | {:name, "name"}
  #   - spec = nil | "<spec>" (e.g. ".2f", ">5")
  # Returns `{:ok, segments}` or `{:error, reason}` for malformed
  # templates (unbalanced braces, nested placeholders, etc.).
  defp parse_format_segments(template) do
    do_parse_format(template, "", [])
  rescue
    _ -> {:error, "couldn't parse template"}
  end

  defp do_parse_format("", acc_text, acc_segments) do
    segments = flush_text(acc_text, acc_segments)
    {:ok, Enum.reverse(segments)}
  end

  defp do_parse_format("{{" <> rest, acc_text, acc_segments),
    do: do_parse_format(rest, acc_text <> "{", acc_segments)

  defp do_parse_format("}}" <> rest, acc_text, acc_segments),
    do: do_parse_format(rest, acc_text <> "}", acc_segments)

  defp do_parse_format("{" <> rest, acc_text, acc_segments) do
    case :binary.split(rest, "}") do
      [inner, after_brace] ->
        case parse_placeholder(inner) do
          {:ok, placeholder} ->
            segments = flush_text(acc_text, acc_segments)
            do_parse_format(after_brace, "", [placeholder | segments])

          {:error, _} = e ->
            e
        end

      [_no_close] ->
        {:error, "unclosed `{` in template"}
    end
  end

  defp do_parse_format("}" <> _rest, _acc_text, _acc_segments),
    do: {:error, "stray `}` in template (use `}}` to escape)"}

  defp do_parse_format(<<ch::utf8, rest::binary>>, acc_text, acc_segments),
    do: do_parse_format(rest, acc_text <> <<ch::utf8>>, acc_segments)

  defp flush_text("", segments), do: segments
  defp flush_text(text, segments), do: [{:text, text} | segments]

  # Inside the `{...}` braces — separate the key from the optional
  # `:SPEC` and classify the key.
  defp parse_placeholder(inner) do
    {key_part, spec} =
      case :binary.split(inner, ":") do
        [k, s] -> {k, s}
        [k] -> {k, nil}
      end

    cond do
      key_part == "" ->
        {:ok, {:placeholder, :auto, spec}}

      String.match?(key_part, ~r/^\d+$/) ->
        {:ok, {:placeholder, {:index, String.to_integer(key_part)}, spec}}

      String.match?(key_part, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/) ->
        {:ok, {:placeholder, {:name, key_part}, spec}}

      true ->
        {:error, "unsupported placeholder key `#{key_part}` (only `{}`, `{N}`, `{name}` for now)"}
    end
  end

  # Walk the segments, resolving each placeholder against `args` (for
  # positional) or `kwargs` (for named), and emit a `<>` chain. The
  # `auto` counter advances each time we resolve a bare `{}`.
  defp build_format_concat(segments, args, kwargs, template, node) do
    {parts, _auto_idx} =
      Enum.map_reduce(segments, 0, fn
        {:text, t}, auto ->
          {t, auto}

        {:placeholder, :auto, spec}, auto ->
          {resolve_positional(auto, args, spec, template, node), auto + 1}

        {:placeholder, {:index, idx}, spec}, auto ->
          {resolve_positional(idx, args, spec, template, node), auto}

        {:placeholder, {:name, name}, spec}, auto ->
          {resolve_named(name, kwargs, spec, template, node), auto}
      end)

    join_with_concat(parts)
  end

  defp resolve_named(name, kwargs, spec, template, node) do
    case Map.fetch(kwargs, name) do
      {:ok, arg_ast} ->
        wrap_with_spec(arg_ast, spec)

      :error ->
        raise UnsupportedNodeError,
          node_type: "Call",
          hint: "`\"#{template}\".format(...)` — keyword `{#{name}}` has no matching kwarg",
          lineno: Map.get(node, "lineno"),
          col_offset: Map.get(node, "col_offset")
    end
  end

  defp resolve_positional(idx, args, spec, template, node) do
    if idx < length(args) do
      wrap_with_spec(Enum.at(args, idx), spec)
    else
      raise UnsupportedNodeError,
        node_type: "Call",
        hint:
          "`\"#{template}\".format(...)` — placeholder index #{idx} but only #{length(args)} positional args given",
        lineno: Map.get(node, "lineno"),
        col_offset: Map.get(node, "col_offset")
    end
  end

  defp wrap_with_spec(arg_ast, nil), do: {:py_str, [], [arg_ast]}
  defp wrap_with_spec(arg_ast, spec), do: {:py_format_value, [], [arg_ast, spec]}

  defp join_with_concat([]), do: ""
  defp join_with_concat([one]), do: one

  defp join_with_concat(parts) do
    [first | rest] = parts
    Enum.reduce(rest, first, fn p, acc -> {:<>, [], [acc, p]} end)
  end

  defp regex_match(target, pattern) do
    {{:., [], [{:__aliases__, [], [:Regex]}, :match?]}, [],
     [{:sigil_r, [], [{:<<>>, [], [pattern]}, []]}, target]}
  end
end
