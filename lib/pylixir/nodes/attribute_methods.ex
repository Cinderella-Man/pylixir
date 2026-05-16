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
  """

  alias Pylixir.UnsupportedNodeError

  @dict_methods ~w(keys values items get)
  @string_methods ~w(lower upper strip lstrip rstrip startswith endswith
                     split replace find count index zfill isdigit isalpha isalnum
                     join)

  @spec dispatch(String.t(), Macro.t(), [Macro.t()], map(), map()) :: Macro.t()
  def dispatch(attr, target_ast, arg_asts, kwargs, node) do
    do_dispatch(attr, target_ast, arg_asts, kwargs, node)
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

  defp do_dispatch("strip", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :trim]}, [], [target]}

  defp do_dispatch("strip", target, [chars], _kw, node) do
    reject_multichar_strip!(chars, node)
    {{:., [], [{:__aliases__, [], [:String]}, :trim]}, [], [target, chars]}
  end

  defp do_dispatch("lstrip", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :trim_leading]}, [], [target]}

  defp do_dispatch("rstrip", target, [], _kw, _node),
    do: {{:., [], [{:__aliases__, [], [:String]}, :trim_trailing]}, [], [target]}

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

  defp do_dispatch("find", target, [sub], _kw, _node),
    do: {:py_str_find, [], [target, sub]}

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

  defp do_dispatch(attr, _target, _args, _kw, node) do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint:
        "method `.#{attr}()` is not supported (allowed: #{Enum.join(@dict_methods ++ @string_methods, ", ")})",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp regex_match(target, pattern) do
    {{:., [], [{:__aliases__, [], [:Regex]}, :match?]}, [],
     [{:sigil_r, [], [{:<<>>, [], [pattern]}, []]}, target]}
  end

  # The chars AST has already been converted by emit_attribute_call — for
  # a Python Constant string, that's just the binary value. Reject if the
  # resulting AST is a multi-char binary literal.
  defp reject_multichar_strip!(chars_ast, node)
       when is_binary(chars_ast) and byte_size(chars_ast) > 1 do
    raise UnsupportedNodeError,
      node_type: "Call",
      hint:
        "str.strip(<multi-char>) is not supported — Python strips ANY of those chars from ends; Elixir's String.trim/2 strips exactly that string (RFC §6.24)",
      lineno: Map.get(node, "lineno"),
      col_offset: Map.get(node, "col_offset")
  end

  defp reject_multichar_strip!(_chars, _node), do: :ok
end
