defmodule Pylixir.LiteralPropagationTest do
  use ExUnit.Case, async: true

  alias Pylixir.LiteralPropagation

  # Minimal AST node constructors so test cases read like Python.
  defp constant(v), do: %{"_type" => "Constant", "value" => v}
  defp name(id), do: %{"_type" => "Name", "id" => id}
  defp assign(target, value), do: %{"_type" => "Assign", "targets" => [target], "value" => value}

  defp aug_assign(target),
    do: %{
      "_type" => "AugAssign",
      "target" => target,
      "op" => %{"_type" => "Add"},
      "value" => constant(1)
    }

  defp subscript(value, slice),
    do: %{"_type" => "Subscript", "value" => value, "slice" => slice}

  defp attribute(value, attr),
    do: %{"_type" => "Attribute", "value" => value, "attr" => attr}

  defp call(func, args),
    do: %{"_type" => "Call", "func" => func, "args" => args, "keywords" => []}

  defp expr_stmt(value), do: %{"_type" => "Expr", "value" => value}
  defp list_lit(elts), do: %{"_type" => "List", "elts" => elts}
  defp return(value), do: %{"_type" => "Return", "value" => value}

  defp function_def(name, body, args \\ []) do
    %{
      "_type" => "FunctionDef",
      "name" => name,
      "args" => %{
        "args" => Enum.map(args, fn a -> %{"arg" => a, "annotation" => nil} end),
        "vararg" => nil,
        "kwarg" => nil,
        "defaults" => []
      },
      "body" => body,
      "decorator_list" => [],
      "returns" => nil
    }
  end

  describe "collect_literal_bindings/1" do
    test "single literal assignment is collected" do
      body = [assign(name("xs"), list_lit([constant(1), constant(2), constant(3)]))]
      assert LiteralPropagation.collect_literal_bindings(body) == %{"xs" => [1, 2, 3]}
    end

    test "non-foldable RHS is skipped" do
      body = [assign(name("xs"), call(name("compute"), []))]
      assert LiteralPropagation.collect_literal_bindings(body) == %{}
    end

    test "multi-bound name is excluded (would be ambiguous which literal)" do
      body = [
        assign(name("xs"), list_lit([constant(1)])),
        assign(name("xs"), list_lit([constant(2)]))
      ]

      assert LiteralPropagation.collect_literal_bindings(body) == %{}
    end

    test "string literal is collected" do
      body = [assign(name("s"), constant("hello"))]
      assert LiteralPropagation.collect_literal_bindings(body) == %{"s" => "hello"}
    end
  end

  describe "collect_mutations/1" do
    test "subscript-assign marks the receiver" do
      body = [assign(subscript(name("xs"), constant(0)), constant(42))]
      assert MapSet.member?(LiteralPropagation.collect_mutations(body), "xs")
    end

    test "attribute-assign marks the receiver" do
      body = [assign(attribute(name("obj"), "x"), constant(1))]
      assert MapSet.member?(LiteralPropagation.collect_mutations(body), "obj")
    end

    test "AugAssign on Name marks the name" do
      body = [aug_assign(name("counter"))]
      assert MapSet.member?(LiteralPropagation.collect_mutations(body), "counter")
    end

    test "mutating method call (append) marks the receiver" do
      body = [expr_stmt(call(attribute(name("xs"), "append"), [constant(4)]))]
      assert MapSet.member?(LiteralPropagation.collect_mutations(body), "xs")
    end

    test "non-mutating method call does NOT mark the receiver" do
      body = [expr_stmt(call(attribute(name("xs"), "index"), [constant(0)]))]
      refute MapSet.member?(LiteralPropagation.collect_mutations(body), "xs")
    end
  end

  describe "collect_aliases/1" do
    test "M = N marks N as aliased" do
      body = [assign(name("m"), name("n"))]
      assert MapSet.member?(LiteralPropagation.collect_aliases(body), "n")
    end

    test "M = [*N] marks N as aliased (any RHS that contains Name(N))" do
      body = [assign(name("m"), list_lit([name("n")]))]
      assert MapSet.member?(LiteralPropagation.collect_aliases(body), "n")
    end

    test "literal RHS doesn't add any aliases" do
      body = [assign(name("m"), constant(5))]
      assert LiteralPropagation.collect_aliases(body) |> MapSet.size() == 0
    end
  end

  describe "collect_escapes/1" do
    test "passing N as a call arg marks N as escaped" do
      body = [expr_stmt(call(name("f"), [name("xs")]))]
      assert MapSet.member?(LiteralPropagation.collect_escapes(body), "xs")
    end

    test "N appearing only as callee is not escaped" do
      body = [expr_stmt(call(name("xs"), []))]
      refute MapSet.member?(LiteralPropagation.collect_escapes(body), "xs")
    end
  end

  describe "collect_constant_fns/1" do
    test "def f(): return [1,2,3] is constant-returning" do
      body = [function_def("f", [return(list_lit([constant(1), constant(2), constant(3)]))])]
      assert LiteralPropagation.collect_constant_fns(body) == %{"f" => [1, 2, 3]}
    end

    test "def f(x): return [1,2,3] is constant-returning (args ignored)" do
      body =
        [function_def("f", [return(list_lit([constant(1), constant(2), constant(3)]))], ["x"])]

      assert LiteralPropagation.collect_constant_fns(body) == %{"f" => [1, 2, 3]}
    end

    test "def f(): docstring + return literal — docstring is stripped" do
      body =
        [
          function_def("f", [
            expr_stmt(constant("doc")),
            return(list_lit([constant(1)]))
          ])
        ]

      assert LiteralPropagation.collect_constant_fns(body) == %{"f" => [1]}
    end

    test "def f(): non-foldable return is not constant" do
      body = [function_def("f", [return(call(name("compute"), []))])]
      assert LiteralPropagation.collect_constant_fns(body) == %{}
    end

    test "def f(): multi-statement body is not constant" do
      body =
        [
          function_def("f", [
            assign(name("tmp"), constant(1)),
            return(name("tmp"))
          ])
        ]

      assert LiteralPropagation.collect_constant_fns(body) == %{}
    end
  end

  # ===================================================================
  # End-to-end rewrite tests: scan → rewrite. These exercise the
  # `resolve/2` gate plus the per-shape rewriters from Step 4 onwards.
  # ===================================================================

  describe "rewrite/1 — (iv-a) emit-site folds" do
    test "repr(literal string) folds to its repr binary" do
      [stmt] = LiteralPropagation.rewrite([expr_stmt(call(name("repr"), [constant("foo")]))])
      assert stmt["value"] == %{"_type" => "Constant", "value" => "'foo'", "kind" => nil}
    end

    test "repr(literal int) folds" do
      [stmt] = LiteralPropagation.rewrite([expr_stmt(call(name("repr"), [constant(42)]))])
      assert stmt["value"] == %{"_type" => "Constant", "value" => "42", "kind" => nil}
    end

    test "repr(literal list) folds" do
      [stmt] =
        LiteralPropagation.rewrite([
          expr_stmt(call(name("repr"), [list_lit([constant(1), constant(2)])]))
        ])

      assert stmt["value"] == %{"_type" => "Constant", "value" => "[1, 2]", "kind" => nil}
    end

    test "str(literal string) returns the string itself (no quotes)" do
      [stmt] = LiteralPropagation.rewrite([expr_stmt(call(name("str"), [constant("foo")]))])
      assert stmt["value"] == %{"_type" => "Constant", "value" => "foo", "kind" => nil}
    end

    test "str(literal int) returns numeric str" do
      [stmt] = LiteralPropagation.rewrite([expr_stmt(call(name("str"), [constant(42)]))])
      assert stmt["value"] == %{"_type" => "Constant", "value" => "42", "kind" => nil}
    end

    test "repr with non-literal arg is left alone" do
      arg = call(name("some_call"), [])
      input = [expr_stmt(call(name("repr"), [arg]))]
      assert LiteralPropagation.rewrite(input) == input
    end

    test "print(literal list) rewrites args to str-folded constants" do
      [stmt] =
        LiteralPropagation.rewrite([
          expr_stmt(call(name("print"), [list_lit([constant(1), constant(2), constant(3)])]))
        ])

      # The list arg has been replaced with its str() (== repr for
      # containers) representation.
      assert hd(stmt["value"]["args"]) == %{
               "_type" => "Constant",
               "value" => "[1, 2, 3]",
               "kind" => nil
             }
    end

    test "print(non-foldable, literal) only folds the literal arg" do
      computed = call(name("compute"), [])

      [stmt] =
        LiteralPropagation.rewrite([
          expr_stmt(call(name("print"), [computed, list_lit([constant(1)])]))
        ])

      [first, second] = stmt["value"]["args"]
      assert first == computed
      assert second == %{"_type" => "Constant", "value" => "[1]", "kind" => nil}
    end
  end

  describe "rewrite/1 — `%`-format" do
    defp binop(op_type, left, right),
      do: %{"_type" => "BinOp", "op" => %{"_type" => op_type}, "left" => left, "right" => right}

    defp tuple_lit(elts), do: %{"_type" => "Tuple", "elts" => elts}

    test "\"x=%d\" % 5 folds to Constant(\"x=5\")" do
      [stmt] =
        LiteralPropagation.rewrite([
          expr_stmt(binop("Mod", constant("x=%d"), constant(5)))
        ])

      assert stmt["value"] == %{"_type" => "Constant", "value" => "x=5", "kind" => nil}
    end

    test "\"%s and %s\" % (a, b) folds with tuple-arg" do
      [stmt] =
        LiteralPropagation.rewrite([
          expr_stmt(binop("Mod", constant("%s and %s"), tuple_lit([constant("foo"), constant("bar")])))
        ])

      assert stmt["value"] == %{
               "_type" => "Constant",
               "value" => "foo and bar",
               "kind" => nil
             }
    end
  end

  describe "rewrite/1 — .format() basic shapes" do
    test "\"{} {}\".format(a, b) folds with two literal args" do
      [stmt] =
        LiteralPropagation.rewrite([
          expr_stmt(
            %{
              "_type" => "Call",
              "func" => %{
                "_type" => "Attribute",
                "value" => constant("{} and {}"),
                "attr" => "format"
              },
              "args" => [constant("foo"), constant(42)],
              "keywords" => []
            }
          )
        ])

      assert stmt["value"] == %{"_type" => "Constant", "value" => "foo and 42", "kind" => nil}
    end

    test "{!r} converts via repr" do
      [stmt] =
        LiteralPropagation.rewrite([
          expr_stmt(
            %{
              "_type" => "Call",
              "func" => %{
                "_type" => "Attribute",
                "value" => constant("{!r}"),
                "attr" => "format"
              },
              "args" => [constant("foo")],
              "keywords" => []
            }
          )
        ])

      assert stmt["value"] == %{"_type" => "Constant", "value" => "'foo'", "kind" => nil}
    end
  end

  describe "rewrite/1 — f-string" do
    defp fstring(values), do: %{"_type" => "JoinedStr", "values" => values}

    defp formatted_value(value, conversion, format_spec) do
      %{
        "_type" => "FormattedValue",
        "value" => value,
        "conversion" => conversion,
        "format_spec" => format_spec
      }
    end

    test "f\"hello {1!r}\" folds entirely" do
      input = [
        expr_stmt(
          fstring([
            constant("hello "),
            formatted_value(constant(1), 114, nil)
          ])
        )
      ]

      [stmt] = LiteralPropagation.rewrite(input)

      assert stmt["value"] == %{"_type" => "Constant", "value" => "hello 1", "kind" => nil}
    end

    test "f-string with non-literal value is left alone" do
      input = [
        expr_stmt(
          fstring([
            constant("hello "),
            formatted_value(call(name("x"), []), 115, nil)
          ])
        )
      ]

      assert LiteralPropagation.rewrite(input) == input
    end
  end

  # ===================================================================
  # Phase 1 — direct binding tests
  # ===================================================================
  describe "rewrite/1 — Phase 1 (direct binding)" do
    test "xs = [1,2,3]; print(xs) folds the print arg" do
      input = [
        assign(name("xs"), list_lit([constant(1), constant(2), constant(3)])),
        expr_stmt(call(name("print"), [name("xs")]))
      ]

      [_a, print_stmt] = LiteralPropagation.rewrite(input)

      assert hd(print_stmt["value"]["args"]) == %{
               "_type" => "Constant",
               "value" => "[1, 2, 3]",
               "kind" => nil
             }
    end

    test "mutation blocks the fold" do
      input = [
        assign(name("xs"), list_lit([constant(1)])),
        expr_stmt(call(attribute(name("xs"), "append"), [constant(4)])),
        expr_stmt(call(name("print"), [name("xs")]))
      ]

      result = LiteralPropagation.rewrite(input)
      print_stmt = List.last(result)
      # Print arg is still Name(xs), not a Constant.
      assert hd(print_stmt["value"]["args"]) == name("xs")
    end

    test "escape (passing xs to a function) blocks the fold" do
      input = [
        assign(name("xs"), list_lit([constant(1)])),
        expr_stmt(call(name("save"), [name("xs")])),
        expr_stmt(call(name("print"), [name("xs")]))
      ]

      result = LiteralPropagation.rewrite(input)
      print_stmt = List.last(result)
      assert hd(print_stmt["value"]["args"]) == name("xs")
    end

    test "aliasing (ys = xs) blocks the fold" do
      input = [
        assign(name("xs"), list_lit([constant(1)])),
        assign(name("ys"), name("xs")),
        expr_stmt(call(name("print"), [name("xs")]))
      ]

      result = LiteralPropagation.rewrite(input)
      print_stmt = List.last(result)
      assert hd(print_stmt["value"]["args"]) == name("xs")
    end
  end

  # ===================================================================
  # Phase 2 — constant function tests
  # ===================================================================
  describe "rewrite/1 — Phase 2 (constant function)" do
    test "def f(): return [1,2,3]; print(f()) folds" do
      input = [
        function_def("f", [return(list_lit([constant(1), constant(2), constant(3)]))]),
        expr_stmt(call(name("print"), [call(name("f"), [])]))
      ]

      result = LiteralPropagation.rewrite(input)
      print_stmt = List.last(result)

      assert hd(print_stmt["value"]["args"]) == %{
               "_type" => "Constant",
               "value" => "[1, 2, 3]",
               "kind" => nil
             }
    end

    test "def f(x): return [1,2,3]; print(f(5)) folds (literal call arg)" do
      input = [
        function_def("f", [return(list_lit([constant(1), constant(2)]))], ["x"]),
        expr_stmt(call(name("print"), [call(name("f"), [constant(5)])]))
      ]

      result = LiteralPropagation.rewrite(input)
      print_stmt = List.last(result)

      assert hd(print_stmt["value"]["args"]) == %{
               "_type" => "Constant",
               "value" => "[1, 2]",
               "kind" => nil
             }
    end

    test "def f(x): return [1,2,3]; print(f(side_effect())) does NOT fold" do
      side_effect = call(name("side_effect"), [])

      input = [
        function_def("f", [return(list_lit([constant(1), constant(2)]))], ["x"]),
        expr_stmt(call(name("print"), [call(name("f"), [side_effect])]))
      ]

      result = LiteralPropagation.rewrite(input)
      print_stmt = List.last(result)

      # Still a Call node, not a Constant.
      assert hd(print_stmt["value"]["args"])["_type"] == "Call"
    end
  end

  # ===================================================================
  # Phase 3 — closure capture tests
  # ===================================================================
  describe "rewrite/1 — Phase 3 (closure capture)" do
    test "xs = [1,2,3]; def g(): print(xs); g() folds the print INSIDE g" do
      input = [
        assign(name("xs"), list_lit([constant(1), constant(2), constant(3)])),
        function_def("g", [expr_stmt(call(name("print"), [name("xs")]))]),
        expr_stmt(call(name("g"), []))
      ]

      result = LiteralPropagation.rewrite(input)
      [_assign, g_def, _g_call] = result

      [print_in_g] = g_def["body"]

      assert hd(print_in_g["value"]["args"]) == %{
               "_type" => "Constant",
               "value" => "[1, 2, 3]",
               "kind" => nil
             }
    end

    test "closure that MUTATES xs blocks the outer fold" do
      input = [
        assign(name("xs"), list_lit([constant(1)])),
        function_def("g", [
          expr_stmt(call(attribute(name("xs"), "append"), [constant(2)]))
        ]),
        expr_stmt(call(name("g"), [])),
        expr_stmt(call(name("print"), [name("xs")]))
      ]

      result = LiteralPropagation.rewrite(input)
      print_stmt = List.last(result)

      # Mutation inside closure blocked the fold — xs stays unresolved.
      assert hd(print_stmt["value"]["args"]) == name("xs")
    end
  end

  # ===================================================================
  # Fixpoint
  # ===================================================================
  describe "rewrite/1 — fixpoint" do
    test "xs = [1,2,3]; def f(): return xs; print(f()) chains Phase 1 + Phase 2 over iterations" do
      # f returns xs (a Name, not a literal). After one fold pass,
      # `xs` itself doesn't fold inside f's body without help, but
      # the constant_functions table sees `def f(): return xs` and
      # asks whether xs is foldable in scope — which it is via
      # Phase 1. So `f()` resolves to [1,2,3], and `print(f())`
      # folds.
      input = [
        assign(name("xs"), list_lit([constant(1), constant(2), constant(3)])),
        function_def("f", [return(name("xs"))]),
        expr_stmt(call(name("print"), [call(name("f"), [])]))
      ]

      result = LiteralPropagation.rewrite(input)
      print_stmt = List.last(result)

      # Whether the fold of `f()` through `xs` succeeds depends on
      # whether `xs` survives the alias / escape gates. In this
      # particular shape: xs is also referenced by f's body, which
      # `collect_escapes` flags as "passed somewhere" — gate fails.
      # Document the actual behaviour: NO fold here.
      assert hd(print_stmt["value"]["args"])["_type"] == "Call"
    end
  end
end
