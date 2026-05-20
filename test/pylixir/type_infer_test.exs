defmodule Pylixir.TypeInferTest do
  use ExUnit.Case, async: true

  alias Pylixir.{Context, TypeInfer}

  defp ctx, do: Context.new()

  defp const(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}

  describe "infer_expr/2 — Constant" do
    test "non-negative int is the literal-nonneg refinement" do
      assert TypeInfer.infer_expr(const(5), ctx()) == {:int_lit_nonneg}
      assert TypeInfer.infer_expr(const(0), ctx()) == {:int_lit_nonneg}
    end

    test "negative int is plain int" do
      assert TypeInfer.infer_expr(const(-1), ctx()) == {:int}
    end

    test "bool is :bool (not :int) — Q7-A" do
      assert TypeInfer.infer_expr(const(true), ctx()) == {:bool}
      assert TypeInfer.infer_expr(const(false), ctx()) == {:bool}
    end

    test "float → :float" do
      assert TypeInfer.infer_expr(const(1.5), ctx()) == {:float}
    end

    test "string → :str" do
      assert TypeInfer.infer_expr(const("hi"), ctx()) == {:str}
    end

    test "None → :none" do
      assert TypeInfer.infer_expr(const(nil), ctx()) == {:none}
    end
  end

  describe "infer_expr/2 — Name lookup" do
    test "returns recorded type for known names" do
      c = TypeInfer.bind(ctx(), "x", {:int})
      assert TypeInfer.infer_expr(name("x"), c) == {:int}
    end

    test "consults heap_types when not in types" do
      c = %{ctx() | heap_types: %{"m" => {:dict, :any, :any}}}
      assert TypeInfer.infer_expr(name("m"), c) == {:dict, :any, :any}
    end

    test "returns :any for unknown names" do
      assert TypeInfer.infer_expr(name("unknown"), ctx()) == :any
    end
  end

  describe "infer_expr/2 — container literals" do
    test "List of ints" do
      list = %{"_type" => "List", "elts" => [const(1), const(2), const(3)]}
      assert TypeInfer.infer_expr(list, ctx()) == {:list, {:int_lit_nonneg}}
    end

    test "List with mixed numeric → numeric tower" do
      list = %{"_type" => "List", "elts" => [const(1), const(1.5)]}
      assert TypeInfer.infer_expr(list, ctx()) == {:list, {:float}}
    end

    test "empty List → {:list, :any}" do
      list = %{"_type" => "List", "elts" => []}
      assert TypeInfer.infer_expr(list, ctx()) == {:list, :any}
    end

    test "Tuple preserves per-slot types" do
      tup = %{"_type" => "Tuple", "elts" => [const(1), const("hi")]}
      assert TypeInfer.infer_expr(tup, ctx()) == {:tuple, [{:int_lit_nonneg}, {:str}]}
    end

    test "Dict produces {:dict, k_lub, v_lub}" do
      d = %{
        "_type" => "Dict",
        "keys" => [const("a"), const("b")],
        "values" => [const(1), const(2)]
      }

      assert TypeInfer.infer_expr(d, ctx()) == {:dict, {:str}, {:int_lit_nonneg}}
    end
  end

  describe "lub/2" do
    test "reflexive" do
      assert TypeInfer.lub({:int}, {:int}) == {:int}
    end

    test ":any absorbs" do
      assert TypeInfer.lub(:any, {:int}) == :any
      assert TypeInfer.lub({:int}, :any) == :any
    end

    test ":bottom is identity" do
      assert TypeInfer.lub(:bottom, {:int}) == {:int}
      assert TypeInfer.lub({:int}, :bottom) == {:int}
    end

    test "int + float = float (numeric tower)" do
      assert TypeInfer.lub({:int}, {:float}) == {:float}
      assert TypeInfer.lub({:float}, {:int}) == {:float}
    end

    test "bool + int = union (Q7-A)" do
      assert TypeInfer.lub({:bool}, {:int}) == {:union, MapSet.new([{:bool}, {:int}])}
    end

    test "int_lit_nonneg + int_lit_nonneg stays nonneg" do
      assert TypeInfer.lub({:int_lit_nonneg}, {:int_lit_nonneg}) == {:int_lit_nonneg}
    end

    test "int_lit_nonneg + int loses refinement" do
      assert TypeInfer.lub({:int_lit_nonneg}, {:int}) == {:int}
      assert TypeInfer.lub({:int}, {:int_lit_nonneg}) == {:int}
    end

    test "int_lit_nonneg + float = float (numeric tower via int promote)" do
      assert TypeInfer.lub({:int_lit_nonneg}, {:float}) == {:float}
    end

    test "list element types joined" do
      assert TypeInfer.lub({:list, {:int}}, {:list, {:str}}) ==
               {:list, {:union, MapSet.new([{:int}, {:str}])}}
    end

    test "matching-arity tuple zip-lubs slots" do
      assert TypeInfer.lub({:tuple, [{:int}, {:str}]}, {:tuple, [{:int}, {:str}]}) ==
               {:tuple, [{:int}, {:str}]}
    end

    test "mismatched-arity tuples degrade to :any_arity" do
      assert TypeInfer.lub({:tuple, [{:int}]}, {:tuple, [{:int}, {:str}]}) ==
               {:tuple, :any_arity}
    end
  end

  describe "elem_of/1" do
    test "list element type" do
      assert TypeInfer.elem_of({:list, {:int}}) == {:int}
    end

    test "str iter is str" do
      assert TypeInfer.elem_of({:str}) == {:str}
    end

    test "tuple iter lubs all slots" do
      assert TypeInfer.elem_of({:tuple, [{:int}, {:int}]}) == {:int}
    end

    test "dict iter is key type" do
      assert TypeInfer.elem_of({:dict, {:str}, {:int}}) == {:str}
    end

    test ":any_arity tuple → :any" do
      assert TypeInfer.elem_of({:tuple, :any_arity}) == :any
    end

    test "alist element type passes through" do
      assert TypeInfer.elem_of({:py_alist, {:int}}) == {:int}
    end
  end

  describe "{:py_alist, _} type variant" do
    test "is_list? returns false so coerce_iter wraps it in py_iter_to_list" do
      refute TypeInfer.is_list?({:py_alist, {:int}})
    end

    test "lub of two alists stays an alist with joined element type" do
      assert TypeInfer.lub({:py_alist, {:int}}, {:py_alist, {:int}}) == {:py_alist, {:int}}

      assert TypeInfer.lub({:py_alist, {:int}}, {:py_alist, {:str}}) ==
               {:py_alist, {:union, MapSet.new([{:int}, {:str}])}}
    end
  end

  describe "bind_pattern/3" do
    test "Name target" do
      target = name("x")
      c = TypeInfer.bind_pattern(target, {:int}, ctx())
      assert c.types["x"] == {:int}
    end

    test "matching-arity Tuple destructure" do
      target = %{
        "_type" => "Tuple",
        "elts" => [name("a"), name("b")]
      }

      c = TypeInfer.bind_pattern(target, {:tuple, [{:int}, {:str}]}, ctx())
      assert c.types["a"] == {:int}
      assert c.types["b"] == {:str}
    end

    test "List source: each elt gets the same element type" do
      target = %{
        "_type" => "Tuple",
        "elts" => [name("a"), name("b"), name("c")]
      }

      c = TypeInfer.bind_pattern(target, {:list, {:int}}, ctx())
      assert c.types["a"] == {:int}
      assert c.types["b"] == {:int}
      assert c.types["c"] == {:int}
    end

    test "arity mismatch → each elt gets :any" do
      target = %{
        "_type" => "Tuple",
        "elts" => [name("a"), name("b"), name("c")]
      }

      c = TypeInfer.bind_pattern(target, {:tuple, [{:int}, {:str}]}, ctx())
      assert c.types["a"] == :any
      assert c.types["b"] == :any
      assert c.types["c"] == :any
    end

    test "Starred unpack — position-aware tuple slicing" do
      target = %{
        "_type" => "Tuple",
        "elts" => [
          name("a"),
          %{"_type" => "Starred", "value" => name("rest")},
          name("b")
        ]
      }

      c =
        TypeInfer.bind_pattern(
          target,
          {:tuple, [{:int}, {:str}, {:str}, {:int}]},
          ctx()
        )

      assert c.types["a"] == {:int}
      assert c.types["b"] == {:int}
      assert c.types["rest"] == {:list, {:str}}
    end

    test "Starred unpack with List source" do
      target = %{
        "_type" => "Tuple",
        "elts" => [
          name("a"),
          %{"_type" => "Starred", "value" => name("rest")}
        ]
      }

      c = TypeInfer.bind_pattern(target, {:list, {:int}}, ctx())
      assert c.types["a"] == {:int}
      assert c.types["rest"] == {:list, {:int}}
    end

    test "Subscript target demotes container element type" do
      c0 = TypeInfer.bind(ctx(), "xs", {:list, {:int}})
      target = %{"_type" => "Subscript", "value" => name("xs"), "slice" => const(0)}
      c1 = TypeInfer.bind_pattern(target, {:str}, c0)
      assert c1.types["xs"] == {:list, :any}
    end
  end

  describe "demote/2" do
    test "demotes :list element to :any" do
      c0 = TypeInfer.bind(ctx(), "xs", {:list, {:int}})
      c1 = TypeInfer.demote(c0, "xs")
      assert c1.types["xs"] == {:list, :any}
    end

    test "demotes :dict element slots to :any" do
      c0 = TypeInfer.bind(ctx(), "d", {:dict, {:str}, {:int}})
      c1 = TypeInfer.demote(c0, "d")
      assert c1.types["d"] == {:dict, :any, :any}
    end

    test "no-op for absent names" do
      c0 = ctx()
      c1 = TypeInfer.demote(c0, "nonexistent")
      assert c1 == c0
    end

    test "no-op for non-container types" do
      c0 = TypeInfer.bind(ctx(), "x", {:int})
      c1 = TypeInfer.demote(c0, "x")
      assert c1.types["x"] == {:int}
    end

    test "also demotes heap_types when name lives there" do
      c0 = %{ctx() | heap_types: %{"m" => {:dict, {:str}, {:int}}}}
      c1 = TypeInfer.demote(c0, "m")
      assert c1.heap_types["m"] == {:dict, :any, :any}
    end
  end

  describe "infer_expr/2 — BinOp" do
    test "int + int = int" do
      node = %{
        "_type" => "BinOp",
        "op" => %{"_type" => "Add"},
        "left" => const(1),
        "right" => const(2)
      }

      assert TypeInfer.infer_expr(node, ctx()) == {:int}
    end

    test "str + str = str" do
      node = %{
        "_type" => "BinOp",
        "op" => %{"_type" => "Add"},
        "left" => const("a"),
        "right" => const("b")
      }

      assert TypeInfer.infer_expr(node, ctx()) == {:str}
    end

    test "list + list = list (lub of elements)" do
      node = %{
        "_type" => "BinOp",
        "op" => %{"_type" => "Add"},
        "left" => %{"_type" => "List", "elts" => [const(1)]},
        "right" => %{"_type" => "List", "elts" => [const(2)]}
      }

      assert TypeInfer.infer_expr(node, ctx()) == {:list, {:int_lit_nonneg}}
    end

    test "bool + int → :any (Q7-A taint inhibits spec)" do
      node = %{
        "_type" => "BinOp",
        "op" => %{"_type" => "Add"},
        "left" => const(true),
        "right" => const(1)
      }

      assert TypeInfer.infer_expr(node, ctx()) == :any
    end

    test "str * int = str" do
      node = %{
        "_type" => "BinOp",
        "op" => %{"_type" => "Mult"},
        "left" => const("a"),
        "right" => const(3)
      }

      assert TypeInfer.infer_expr(node, ctx()) == {:str}
    end

    test "Div is always float" do
      node = %{
        "_type" => "BinOp",
        "op" => %{"_type" => "Div"},
        "left" => const(4),
        "right" => const(2)
      }

      assert TypeInfer.infer_expr(node, ctx()) == {:float}
    end
  end

  describe "infer_expr/2 — Subscript" do
    test "list subscript returns element type" do
      c = TypeInfer.bind(ctx(), "xs", {:list, {:int}})
      node = %{"_type" => "Subscript", "value" => name("xs"), "slice" => const(0)}
      assert TypeInfer.infer_expr(node, c) == {:int}
    end

    test "dict subscript always returns :any (Q1-B)" do
      c = TypeInfer.bind(ctx(), "d", {:dict, {:str}, {:int}})
      node = %{"_type" => "Subscript", "value" => name("d"), "slice" => const("k")}
      assert TypeInfer.infer_expr(node, c) == :any
    end

    test "tuple subscript with literal nonneg int picks the slot" do
      c = TypeInfer.bind(ctx(), "p", {:tuple, [{:int}, {:str}]})
      node = %{"_type" => "Subscript", "value" => name("p"), "slice" => const(1)}
      assert TypeInfer.infer_expr(node, c) == {:str}
    end
  end

  describe "module_summary/2 — heap typing (PR 3)" do
    defp module_ctx_with_mutable(names) do
      %{ctx() | mutable_module_dicts: MapSet.new(names)}
    end

    test "seeds heap_types from initial Assign of an empty dict (demoted)" do
      ctx0 = module_ctx_with_mutable(["m"])

      stmts = [
        %{
          "_type" => "Assign",
          "targets" => [name("m")],
          "value" => %{"_type" => "Dict", "keys" => [], "values" => []}
        }
      ]

      ctx1 = TypeInfer.module_summary(stmts, ctx0)
      assert ctx1.heap_types["m"] == {:dict, :any, :any}
    end

    test "seeds heap_types from initial Assign of a non-empty dict — elements demoted" do
      ctx0 = module_ctx_with_mutable(["m"])

      stmts = [
        %{
          "_type" => "Assign",
          "targets" => [name("m")],
          "value" => %{
            "_type" => "Dict",
            "keys" => [const("a")],
            "values" => [const(1)]
          }
        }
      ]

      ctx1 = TypeInfer.module_summary(stmts, ctx0)
      # Element types demoted to :any (Q5-C) even though the literal is
      # typeable; mutation makes refinement unsound.
      assert ctx1.heap_types["m"] == {:dict, :any, :any}
    end

    test "seeds heap_types from initial Assign of a list" do
      ctx0 = module_ctx_with_mutable(["xs"])

      stmts = [
        %{
          "_type" => "Assign",
          "targets" => [name("xs")],
          "value" => %{"_type" => "List", "elts" => [const(1), const(2)]}
        }
      ]

      ctx1 = TypeInfer.module_summary(stmts, ctx0)
      assert ctx1.heap_types["xs"] == {:list, :any}
    end

    test "non-mutable names are skipped" do
      ctx0 = module_ctx_with_mutable([])

      stmts = [
        %{
          "_type" => "Assign",
          "targets" => [name("m")],
          "value" => %{"_type" => "Dict", "keys" => [], "values" => []}
        }
      ]

      ctx1 = TypeInfer.module_summary(stmts, ctx0)
      assert ctx1.heap_types == %{}
    end

    test "only the FIRST assign of a name pins the type (initial init)" do
      ctx0 = module_ctx_with_mutable(["m"])

      stmts = [
        %{
          "_type" => "Assign",
          "targets" => [name("m")],
          "value" => %{"_type" => "Dict", "keys" => [], "values" => []}
        },
        %{
          "_type" => "Assign",
          "targets" => [name("m")],
          "value" => %{"_type" => "List", "elts" => []}
        }
      ]

      ctx1 = TypeInfer.module_summary(stmts, ctx0)
      assert ctx1.heap_types["m"] == {:dict, :any, :any}
    end

    test "Name reads for heap-typed names return the recorded type" do
      ctx0 = module_ctx_with_mutable(["m"])

      stmts = [
        %{
          "_type" => "Assign",
          "targets" => [name("m")],
          "value" => %{"_type" => "Dict", "keys" => [], "values" => []}
        }
      ]

      ctx1 = TypeInfer.module_summary(stmts, ctx0)
      assert TypeInfer.infer_expr(name("m"), ctx1) == {:dict, :any, :any}
    end
  end

  describe "type_of_term/1" do
    test "matches Constant typing for primitives" do
      assert TypeInfer.type_of_term(5) == {:int_lit_nonneg}
      assert TypeInfer.type_of_term(-1) == {:int}
      assert TypeInfer.type_of_term(true) == {:bool}
      assert TypeInfer.type_of_term("hi") == {:str}
      assert TypeInfer.type_of_term(nil) == {:none}
    end

    test "list of ints" do
      assert TypeInfer.type_of_term([1, 2, 3]) == {:list, {:int_lit_nonneg}}
    end

    test "map" do
      assert TypeInfer.type_of_term(%{"a" => 1}) == {:dict, {:str}, {:int_lit_nonneg}}
    end
  end
end
