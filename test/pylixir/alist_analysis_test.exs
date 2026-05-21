defmodule Pylixir.AlistAnalysisTest do
  use ExUnit.Case, async: false

  alias Pylixir.AlistAnalysis

  # --- AST builders (mirror module_analysis_test.exs) -----------------

  defp const(value), do: %{"_type" => "Constant", "value" => value}
  defp name(id), do: %{"_type" => "Name", "id" => id}

  defp assign(target_id, value),
    do: %{"_type" => "Assign", "targets" => [name(target_id)], "value" => value}

  defp subscript_assign(target_id, idx_value, value),
    do: %{
      "_type" => "Assign",
      "targets" => [
        %{"_type" => "Subscript", "value" => name(target_id), "slice" => const(idx_value)}
      ],
      "value" => value
    }

  defp aug_assign(target_id, op_value),
    do: %{"_type" => "AugAssign", "target" => name(target_id), "value" => op_value}

  defp call(func, args, keywords \\ []),
    do: %{"_type" => "Call", "func" => func, "args" => args, "keywords" => keywords}

  defp call_name(fname, args, keywords \\ []),
    do: call(name(fname), args, keywords)

  defp method_call(recv_id, method, args, keywords \\ []),
    do: %{
      "_type" => "Expr",
      "value" =>
        call(
          %{"_type" => "Attribute", "value" => name(recv_id), "attr" => method},
          args,
          keywords
        )
    }

  defp subscript_read(target_id, idx_value),
    do: %{"_type" => "Subscript", "value" => name(target_id), "slice" => const(idx_value)}

  defp for_stmt(target_id, iter, body),
    do: %{
      "_type" => "For",
      "target" => name(target_id),
      "iter" => iter,
      "body" => body,
      "orelse" => []
    }

  defp expr(value), do: %{"_type" => "Expr", "value" => value}
  defp return(value), do: %{"_type" => "Return", "value" => value}

  defp list_literal(elts), do: %{"_type" => "List", "elts" => elts}

  defp fn_def(name_str, body),
    do: %{"_type" => "FunctionDef", "name" => name_str, "body" => body}

  # `xs = list(<other_name>)` — the only RHS shape we currently
  # consider for freezing.
  defp list_call_bind(target_id, arg_id \\ "source"),
    do: assign(target_id, call_name("list", [name(arg_id)]))

  defp compare_in(left, right, op_type),
    do: %{
      "_type" => "Compare",
      "left" => left,
      "ops" => [%{"_type" => op_type}],
      "comparators" => [right]
    }

  # --- Tests ---------------------------------------------------------

  describe "happy path" do
    test "xs = list(...) followed only by indexed reads + len → frozen" do
      body = [
        list_call_bind("xs"),
        expr(call_name("len", [name("xs")])),
        expr(subscript_read("xs", 0))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new(["xs"])
    end

    test "iteration via `for v in xs` is read-only and stays freezable" do
      body = [
        list_call_bind("xs"),
        for_stmt("v", name("xs"), [expr(call_name("print", [name("v")]))])
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new(["xs"])
    end

    test "membership `v in xs` is read-only and stays freezable" do
      body = [
        list_call_bind("xs"),
        expr(compare_in(name("v"), name("xs"), "In"))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new(["xs"])
    end

    test "allowlisted builtins (sum, sorted) and read-only methods (count) stay freezable" do
      body = [
        list_call_bind("xs"),
        expr(call_name("sum", [name("xs")])),
        expr(call_name("sorted", [name("xs")])),
        expr(
          call(%{"_type" => "Attribute", "value" => name("xs"), "attr" => "count"}, [const(7)])
        )
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new(["xs"])
    end
  end

  describe "mutation disqualifiers" do
    test "mutating method call (.append) bails" do
      body = [
        list_call_bind("xs"),
        method_call("xs", "append", [const(7)])
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "subscript-assign xs[i] = v bails" do
      body = [
        list_call_bind("xs"),
        subscript_assign("xs", 0, const(99))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "augmented assign xs += [y] bails" do
      body = [
        list_call_bind("xs"),
        aug_assign("xs", list_literal([const(99)]))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "reassignment xs = ... bails" do
      body = [
        list_call_bind("xs"),
        assign("xs", list_literal([const(1)]))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "del xs[i] bails" do
      body = [
        list_call_bind("xs"),
        %{
          "_type" => "Delete",
          "targets" => [
            %{"_type" => "Subscript", "value" => name("xs"), "slice" => const(0)}
          ]
        }
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end
  end

  describe "leak / alias disqualifiers" do
    test "aliasing y = xs bails (y could be mutated, sharing reference)" do
      body = [
        list_call_bind("xs"),
        assign("y", name("xs"))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "container leak [xs, xs] bails" do
      body = [
        list_call_bind("xs"),
        assign("pair", list_literal([name("xs"), name("xs")]))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "passing to a non-allowlisted function f(xs) bails" do
      body = [
        list_call_bind("xs"),
        expr(call_name("user_fn", [name("xs")]))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "return xs bails (escapes the scope)" do
      body = [
        list_call_bind("xs"),
        return(name("xs"))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "xs in y (opposite direction from v in xs) bails" do
      body = [
        list_call_bind("xs"),
        expr(compare_in(name("xs"), name("y"), "In"))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "arithmetic xs + y bails" do
      body = [
        list_call_bind("xs"),
        expr(%{
          "_type" => "BinOp",
          "left" => name("xs"),
          "op" => %{"_type" => "Add"},
          "right" => name("y")
        })
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end
  end

  describe "nested-scope rules (precise via descending walks)" do
    test "read-only mention of xs inside a nested def is SAFE (no leak, no mutation)" do
      body = [
        list_call_bind("xs"),
        fn_def("inner", [expr(call_name("print", [name("xs")]))])
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new(["xs"])
    end

    test "read-only mention inside a lambda body is SAFE" do
      body = [
        list_call_bind("xs"),
        assign(
          "f",
          %{
            "_type" => "Lambda",
            "args" => %{"args" => []},
            "body" => subscript_read("xs", 0)
          }
        )
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new(["xs"])
    end

    test "read-only mention inside a list comprehension is SAFE (sample 009 pattern)" do
      # `r = [i - xs[i] for i in range(n)]`
      list_comp = %{
        "_type" => "ListComp",
        "elt" => %{
          "_type" => "BinOp",
          "left" => name("i"),
          "op" => %{"_type" => "Sub"},
          "right" => subscript_read("xs", "i")
        },
        "generators" => [
          %{
            "_type" => "comprehension",
            "target" => name("i"),
            "iter" => call_name("range", [name("n")]),
            "ifs" => [],
            "is_async" => 0
          }
        ]
      }

      body = [
        list_call_bind("xs"),
        assign("r", list_comp)
      ]

      # Both freeze: `xs` was always a freezable candidate; `r` is a
      # ListComp bind, which Task-2 widened the gate to accept as a
      # fresh-list source.
      assert AlistAnalysis.freezable_names(body) == MapSet.new(["xs", "r"])
    end

    test "MUTATION inside a nested def bails (descending walk catches it)" do
      body = [
        list_call_bind("xs"),
        fn_def("inner", [method_call("xs", "append", [const(0)])])
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "LEAK inside a nested def bails (return xs / alias inside the closure)" do
      body = [
        list_call_bind("xs"),
        fn_def("inner", [return(name("xs"))])
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "a nested function that doesn't mention xs is fine" do
      body = [
        list_call_bind("xs"),
        fn_def("inner", [expr(call_name("print", [const(42)]))]),
        expr(subscript_read("xs", 0))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new(["xs"])
    end
  end

  describe "candidate discovery" do
    test "only `xs = list(...)` shape qualifies; list literal `xs = [1,2]` does not" do
      body = [
        assign("xs", list_literal([const(1), const(2)])),
        expr(subscript_read("xs", 0))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end

    test "multiple candidates handled independently — one bails, the other freezes" do
      body = [
        list_call_bind("xs", "a"),
        list_call_bind("ys", "b"),
        method_call("xs", "append", [const(0)]),
        expr(subscript_read("ys", 0))
      ]

      assert AlistAnalysis.freezable_names(body) == MapSet.new(["ys"])
    end

    test "candidates inside a nested def are NOT collected from the outer scope" do
      body = [
        fn_def("inner", [list_call_bind("hidden", "src")])
      ]

      # `hidden` is inside `inner`; outer scope sees no candidates.
      assert AlistAnalysis.freezable_names(body) == MapSet.new()
    end
  end

  describe "debug knob: PYLIXIR_DISABLE_ALIST" do
    test "set to 1 → freezable_names returns the empty set unconditionally" do
      body = [
        list_call_bind("xs"),
        expr(subscript_read("xs", 0))
      ]

      System.put_env("PYLIXIR_DISABLE_ALIST", "1")

      try do
        assert AlistAnalysis.freezable_names(body) == MapSet.new()
      after
        System.delete_env("PYLIXIR_DISABLE_ALIST")
      end
    end

    test "set to 0 or empty → no effect (feature enabled as normal)" do
      body = [
        list_call_bind("xs"),
        expr(subscript_read("xs", 0))
      ]

      System.put_env("PYLIXIR_DISABLE_ALIST", "0")

      try do
        assert AlistAnalysis.freezable_names(body) == MapSet.new(["xs"])
      after
        System.delete_env("PYLIXIR_DISABLE_ALIST")
      end
    end
  end
end
