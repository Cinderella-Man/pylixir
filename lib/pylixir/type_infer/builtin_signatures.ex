defmodule Pylixir.TypeInfer.BuiltinSignatures do
  @moduledoc """
  Static return-type signatures for Python built-in calls and methods —
  the lookup-table half of `Pylixir.TypeInfer`. See `CONTEXT.md` →
  "Type inference" for the split rationale.

  Three surfaces:

    * `return_type/3` — Python `Call(Name=<builtin>, args=[...])`:
      `len → {:int_lit_nonneg}`, `range → {:list, {:int}}`,
      `isinstance → {:bool}`, etc. Iterator-aware where possible
      (`sorted(xs)` preserves the element type by recursing through
      `TypeInfer.infer_expr/2` on `xs`).

    * `method_return_type/1` — Python `Call(Attribute=<method>, ...)`:
      `.startswith → {:bool}`, `.split → {:list, {:str}}`, etc.
      Pure name-dispatch; no Context state, no recursive inference.

    * `function_return_type/2` — given a function-valued AST node
      (`Name(id)` consulting `Context.fn_signatures`, or `Lambda`
      recursing through `TypeInfer.infer_expr/2`), recovers the
      function's inferred return type. Used by `return_type/3`'s
      `map(f, xs)` clause to refine `{:list, :any}` → `{:list, ret}`.

  This module deliberately depends on `TypeInfer` (for `infer_expr/2`,
  `elem_of/1`, `lub_all/1`, `demote_bottom/1`). The reverse dependency
  (`TypeInfer.infer_expr/2` → `BuiltinSignatures.return_type/3`) is
  also intentional — the Call clause routes here. Elixir handles the
  mutual reference transparently.

  Adding a new Python builtin's return type = one new clause in
  `return_type/3`. Adding a new method = one new clause in
  `method_return_type/1`. No edits to the inference walker.
  """

  alias Pylixir.{Context, TypeInfer}

  @type t :: TypeInfer.t()

  @spec return_type(String.t(), [map()], Context.t()) :: t()
  def return_type(id, args, ctx) do
    case {id, args} do
      # String/int conversions
      {"int", _} -> {:int}
      {"str", _} -> {:str}
      {"bool", _} -> {:bool}
      {"float", _} -> {:float}
      {"hex", _} -> {:str}
      {"oct", _} -> {:str}
      {"bin", _} -> {:str}
      {"chr", _} -> {:str}
      {"repr", _} -> {:str}
      {"format", _} -> {:str}
      {"ord", _} -> {:int}
      {"abs", _} -> :any
      {"round", _} -> :any
      {"input", _} -> {:str}
      # `len` always returns a non-negative int.
      {"len", _} -> {:int_lit_nonneg}
      # `range(...)` always yields a list of ints (lowered as Enum.to_list of a Range).
      {"range", _} -> {:list, {:int}}
      # `sorted(xs)` preserves the element type.
      {"sorted", [xs | _]} -> {:list, TypeInfer.elem_of(TypeInfer.infer_expr(xs, ctx))}
      {"sorted", []} -> {:list, :any}
      # `reversed(xs)` likewise.
      {"reversed", [xs]} -> {:list, TypeInfer.elem_of(TypeInfer.infer_expr(xs, ctx))}
      # `enumerate(xs)` → list of (int, elt) tuples.
      {"enumerate", [xs | _]} ->
        {:list, {:tuple, [{:int}, TypeInfer.elem_of(TypeInfer.infer_expr(xs, ctx))]}}

      # `zip(a, b, ...)` → list of tuples (arity = len(args)).
      {"zip", _} ->
        {:list, {:tuple, :any_arity}}

      # T7 — `map(f, xs)` returns `{:list, return_type_of(f)}` when `f`
      # is a Name-reference to a typed function or an inlinable Lambda.
      # Falls through to `{:list, :any}` for unknown function shapes.
      {"map", [f, _]} ->
        case function_return_type(f, ctx) do
          :any -> {:list, :any}
          ret -> {:list, ret}
        end

      {"map", _} ->
        {:list, :any}

      # `filter(f, xs)` — element type unchanged (filter preserves).
      {"filter", [_, xs]} ->
        {:list, TypeInfer.elem_of(TypeInfer.infer_expr(xs, ctx))}

      {"filter", _} ->
        {:list, :any}

      # `sum` keeps :any (could be int or float; arg-dependent).
      {"sum", _} ->
        :any

      {"min", [xs]} ->
        TypeInfer.elem_of(TypeInfer.infer_expr(xs, ctx))

      {"max", [xs]} ->
        TypeInfer.elem_of(TypeInfer.infer_expr(xs, ctx))

      {"min", args_list} ->
        TypeInfer.lub_all(Enum.map(args_list, &TypeInfer.infer_expr(&1, ctx)))

      {"max", args_list} ->
        TypeInfer.lub_all(Enum.map(args_list, &TypeInfer.infer_expr(&1, ctx)))

      # Container constructors with no args → empty value of that type.
      {"list", []} ->
        {:list, :any}

      # `list(iter)` passes through the element type when the arg is
      # already a typed list (the common `list(map(...))` shape) —
      # unlocks S3's inline path on typed-result HOF chains.
      {"list", [x | _]} ->
        case TypeInfer.infer_expr(x, ctx) do
          {:list, e} -> {:list, e}
          _ -> {:list, :any}
        end

      {"tuple", _} -> {:tuple, :any_arity}
      {"set", _} -> {:set}
      {"frozenset", _} -> {:set}
      {"dict", _} -> {:dict, :any, :any}
      {"deque", _} -> {:list, :any}
      {"bytearray", _} -> {:list, :any}
      {"bytes", _} -> {:list, :any}
      {"any", _} -> {:bool}
      {"all", _} -> {:bool}
      # T6 — predicate builtins. Refining `:any` → `{:bool}` lets
      # `convert_test/2`'s S1 elision drop the `truthy?` wrap for
      # `if isinstance(x, T):` and `if isinstance(x, T1) or isinstance(x, T2):`
      # shapes (BoolOp of two bool-returning calls also lubs to `{:bool}`).
      {"isinstance", _} -> {:bool}
      {"callable", _} -> {:bool}
      {"hasattr", _} -> {:bool}
      {"issubclass", _} -> {:bool}
      _ -> :any
    end
  end

  @doc """
  Return-type table for the common Python method calls (`s.startswith()`,
  `xs.append()`, etc.). Ducktyped — we trust the source. Methods not
  listed return `:any`.
  """
  @spec method_return_type(String.t()) :: t()
  def method_return_type(method) do
    case method do
      m
      when m in [
             "startswith",
             "endswith",
             "isdigit",
             "isalpha",
             "isalnum",
             "islower",
             "isupper",
             "isspace",
             "isdecimal",
             "isnumeric",
             "isascii",
             "issubset",
             "issuperset",
             "isdisjoint"
           ] ->
        {:bool}

      m
      when m in [
             "lower",
             "upper",
             "title",
             "capitalize",
             "swapcase",
             "casefold",
             "strip",
             "lstrip",
             "rstrip",
             "replace",
             "removeprefix",
             "removesuffix",
             "zfill",
             "ljust",
             "rjust",
             "center",
             "format",
             "join"
           ] ->
        {:str}

      m when m in ["count", "find", "rfind", "index", "bit_length"] ->
        {:int_lit_nonneg}

      m when m in ["split", "rsplit", "splitlines"] ->
        {:list, {:str}}

      m when m in ["keys", "values"] ->
        {:list, :any}

      m when m in ["items"] ->
        {:list, {:tuple, :any_arity}}

      _ ->
        :any
    end
  end

  @doc """
  Recover the inferred return type of a function-valued AST node for
  use in higher-order builtin typing (`map(f, xs)` etc.). Returns
  `:any` when the function shape isn't recognized — caller's
  fallback path stays correct.
  """
  @spec function_return_type(map(), Context.t()) :: t()
  def function_return_type(%{"_type" => "Name", "id" => id}, ctx) do
    case Map.get(ctx.fn_signatures, id) do
      {_params, ret} -> ret
      _ -> :any
    end
  end

  def function_return_type(%{"_type" => "Lambda"} = lambda, ctx) do
    # Reuse the Lambda inference clause from `TypeInfer.infer_expr/2`.
    TypeInfer.infer_expr(lambda, ctx)
  end

  def function_return_type(_, _ctx), do: :any
end
